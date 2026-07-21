const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const nz = shared.numz;
const AssetServer = shared.AssetServer;
const system = @import("../system.zig");
const World = system.World;
const shaderc = @import("shaderc");
const Instance = @import("Vulkan/Instance.zig");
const DebugMessenger = @import("Vulkan/DebugMessenger.zig");
const PhysicalDevice = @import("Vulkan/device.zig").Physical;
const Device = @import("Vulkan/device.zig").Logical;
const Mesh = @import("Vulkan/Mesh.zig");
const Node = @import("Vulkan/Node.zig");
const gltf = @import("Vulkan/gltf.zig");
const SkeletonInstance = @import("Vulkan/SkeletonInstance.zig");
const AnimationClip = @import("Vulkan/AnimationClip.zig");
const Vma = @import("Vulkan/Vma.zig");
const Swapchain = @import("Vulkan/Swapchain.zig");
const FrameData = @import("Vulkan/FrameData.zig");
const Surface = @import("Vulkan/Surface.zig");
const Image = @import("Vulkan/Image.zig");
const Resources = @import("Vulkan/Resources.zig");
const Shader = @import("Vulkan/Shader.zig");
const Ui = @import("Vulkan/Ui.zig");
const procs = @import("Vulkan/procs.zig");
const ext = procs.device.ProcTable;
const tracy = @import("ztracy");

const check = @import("Vulkan/utils.zig").check;

pub const Info = system.Info;
pub const c = @import("vulkan");
const max_frames_inflight: usize = FrameData.max_frames_inflight;
const shadow_splits = [Resources.shadow_cascade_count]f32{ 16, 48, 120 };

pub const Model = @import("Vulkan/Model.zig");

const PlanetCpuChunk = struct {
    coord: nz.Vec3(i32),
    vertices: []Mesh.StaticVertex,
    indices: []u32,
};

const PlanetChunkSet = struct {
    radius: u32,
    center: ?nz.Vec3(i32),
    reach: i32,
    meshes: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Mesh),
};

const PlanetChunkJobState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    id: shared.entity.Id,
    radius: u32,
    center: nz.Vec3(i32),
    reach: i32,
    existing: []nz.Vec3(i32),
    chunks: std.ArrayList(PlanetCpuChunk) = .empty,
    mutex: std.Io.Mutex = .init,
    done: bool = false,
    err: ?anyerror = null,
};

const PlanetChunkJob = struct {
    thread: std.Thread,
    state: *PlanetChunkJobState,
};

gpa: std.mem.Allocator,

instance: Instance,
debug_messenger: ?DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
vma: Vma,
swapchain: Swapchain,
resources: *Resources,
skeletons: std.AutoHashMap(shared.entity.Id, SkeletonInstance),
planet_chunks: std.AutoHashMap(shared.entity.Id, PlanetChunkSet),
planet_chunk_job: ?PlanetChunkJob,
current_frame_inflight: u32,
frames: [max_frames_inflight]FrameData,
ui: Ui,

pub const InitOptions = struct {
    instance: struct {
        extensions: []const [*:0]const u8,
        layers: []const [*:0]const u8,
    },
    device: struct {
        extensions: []const [*:0]const u8,
    },
    surface: struct {
        data: ?*anyopaque = null,
        init: ?*const fn (c.VkInstance, *anyopaque) anyerror!c.VkSurfaceKHR = null,
    } = .{},
    swapchain: struct {
        width: u32,
        heigth: u32,
    },
};

pub fn init(gpa: std.mem.Allocator, asset_server: *AssetServer, options: InitOptions) !*Vulkan {
    const self = try gpa.create(Vulkan);
    self.gpa = gpa;
    self.skeletons = .init(gpa);
    self.planet_chunks = .init(gpa);
    self.planet_chunk_job = null;
    self.current_frame_inflight = 0;

    self.instance = try .init(gpa, options.instance.extensions, options.instance.layers);
    procs.instance.load(self.instance.handle, null);
    self.debug_messenger = if (builtin.mode == .Debug) try .init(self.instance, .{
        .severities = if (try std.process.Environ.contains(.empty, gpa, "RENDERDOC_CAPFILE")) .{} else .{
            .warning = true,
            .verbose = true,
            .@"error" = true,
            .info = true,
        },
    }) else null;
    self.surface = if (options.surface.init != null and options.surface.data != null) .{
        .handle = @ptrCast(try options.surface.init.?(self.instance.handle, options.surface.data.?)),
    } else return error.configSurface;

    self.physical_device = try .pick(self.instance, self.surface.handle);
    self.device = try .init(self.physical_device, options.device.extensions);
    procs.device.load(self.device.handle, null);

    self.vma = try .init(self.instance, self.physical_device, self.device);

    self.swapchain = try .init(gpa, self.vma, self.physical_device, self.device, self.surface, options.swapchain.width, options.swapchain.heigth);

    for (&self.frames) |*frame| {
        frame.* = try .init(self.vma, self.device);
        // std.debug.print("PTR: {*}\n", .{&frame.gpu_scene.buffer});
    }

    self.resources = try .init(gpa, self.vma, self.physical_device, self.device, asset_server);
    try asset_server.load();

    self.ui = try .init(
        gpa,
        self.vma,
        self.device,
        self.swapchain.extent.width,
        self.swapchain.extent.height,
        &self.resources.font,
    );

    return self;
}

pub fn deinit(self: *Vulkan, gpa: std.mem.Allocator) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};

    self.resources.deinit(gpa, self.vma, self.device);

    self.clearSkeletons(gpa);
    self.skeletons.deinit();
    var planet_chunk_iterator = self.planet_chunks.valueIterator();
    while (planet_chunk_iterator.next()) |set| deinitPlanetChunkMap(&set.meshes, gpa, self.vma);
    self.planet_chunks.deinit();
    if (self.planet_chunk_job) |job| {
        job.thread.join();
        deinitPlanetChunkJob(job.state);
        gpa.destroy(job.state);
    }

    self.ui.deinit(gpa, self.vma);
    for (&self.frames) |*frame| frame.deinit(self.vma, self.device);
    self.swapchain.deinit(self.vma, self.device);
    self.vma.deinit();
    self.device.deinit();
    self.surface.deinit(self.instance);
    if (self.debug_messenger) |debug_messenger| debug_messenger.deinit(self.instance);
    self.instance.deinit();
}

pub fn rebindProcs(self: *Vulkan) void {
    procs.instance.load(self.instance.handle, null);
    procs.device.load(self.device.handle, null);
}

pub fn update(self: *Vulkan, info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    // const time = data.delta_time;
    // const elapsed_time = data.elapsed_time;
    var image_index: u32 = undefined;
    var current_frame = &self.frames[self.current_frame_inflight % self.frames.len];
    try check(c.vkWaitForFences(self.device.handle, 1, &current_frame.render_fence, 1, 1000000000));
    // std.debug.print("------------ {d} \n", .{image_index});
    const aquire_result = c.vkAcquireNextImageKHR(
        self.device.handle,
        self.swapchain.swapchain,
        1000000000,
        current_frame.swapchain_semaphore,
        null,
        &image_index,
    );
    // std.debug.print("Acquire result={d} image_index={d}\n", .{ aquire_result, image_index });
    switch (aquire_result) {
        c.VK_ERROR_OUT_OF_DATE_KHR,
        => return,
        c.VK_TIMEOUT, c.VK_NOT_READY => return,
        else => {},
    }
    try check(c.vkResetFences(self.device.handle, 1, &current_frame.render_fence));
    const render_semaphore: c.VkSemaphore = self.swapchain.render_semaphores[image_index];
    // try current_frame.descriptor.clearPools(self.device);
    // current_frame.gpu_scene.deinit(self.vma.handle);

    const cmd_buffer = current_frame.command_buffer;
    try check(c.vkResetCommandBuffer(cmd_buffer, 0));
    var cmd_begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(c.vkBeginCommandBuffer(cmd_buffer, &cmd_begin_info));

    try render(self, cmd_buffer, current_frame, info);

    var swapchain_image_barrier: Image.Barrier = .init(cmd_buffer, self.swapchain.images[image_index], c.VK_IMAGE_ASPECT_COLOR_BIT);
    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT);
    self.swapchain.draw_image.copyOntoImage(
        cmd_buffer,
        .{ .vk_image = self.swapchain.images[image_index], .extent = self.swapchain.extent },
    );

    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
    try check(c.vkEndCommandBuffer(cmd_buffer));

    var submit_info: c.VkSubmitInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = current_frame.swapchain_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT_KHR,
            .value = 0,
        },
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = render_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
            .value = 0,
        },
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cmd_buffer,
        },
    };

    try check(c.vkQueueSubmit2(self.device.graphics_queue, 1, &submit_info, current_frame.render_fence));

    var present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pSwapchains = &self.swapchain.swapchain,
        .swapchainCount = 1,
        .pWaitSemaphores = &render_semaphore,
        .waitSemaphoreCount = 1,
        .pImageIndices = &image_index,
    };

    const present_result = c.vkQueuePresentKHR(self.device.graphics_queue, &present_info);

    if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR) {
        return;
        // self.swapchain.recreate(self.physical_device, self.device, self.surface, )
    }
    self.current_frame_inflight += 1;
}

pub fn render(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, info: *const Info) !void {
    const elapsed_time = info.elapsed_time;
    var draw_image_barrier: Image.Barrier = .init(cmd, self.swapchain.draw_image.vk_image, c.VK_IMAGE_ASPECT_COLOR_BIT);

    draw_image_barrier.transition(
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    );
    var depth_image_barrier: Image.Barrier = .init(cmd, self.swapchain.depth_image.vk_image, c.VK_IMAGE_ASPECT_DEPTH_BIT);
    depth_image_barrier.transition(
        c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    );
    var color_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swapchain.draw_image.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = c.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{
            .color = .{
                // .float32 = .{ (@sin(info.elapsed_time) + 1) / 2, (@cos(info.elapsed_time) + 1) / 2, (@tan(info.elapsed_time) + 1) / 2, 1.0 },
                .float32 = .{ 0, 0, 0, 1 },
            },
        },
    };
    var depth_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = self.swapchain.depth_image.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{
            .depthStencil = .{
                .depth = 1,
                .stencil = 0,
            },
        },
    };
    var render_info: c.VkRenderingInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .height = self.swapchain.draw_image.extent.height,
                .width = self.swapchain.draw_image.extent.width,
            },
        },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
        .pDepthAttachment = &depth_attachment,
        .pStencilAttachment = null,
    };

    setDefaultRenderState(self, cmd, elapsed_time);

    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    const aspect: f32 = width / height;

    const camera_transform = info.world.camera.transform;
    const view = getViewMatrix(&camera_transform);
    const fov_rad: f32 = info.world.camera.fov_rad;
    var proj = perspective(fov_rad, aspect, 0.01, 1000);
    const proj_view = proj.mul(view);

    const light_time = info.elapsed_time * 0.01 + 0.9;
    const light_dir = nz.vec.normalize(@as(nz.Vec3(f32), .{ @cos(light_time), @sin(light_time), 0.3 }));
    var scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_view_proj = proj_view.inverse().d,
        .global_light_direction = light_dir,
        .time = elapsed_time,
        .camera_position = camera_transform.position,
        .light_color = if (info.world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{
            1, 0.5, 0.5, 1,
        },
        .camera_up = up: {
            const up = camera_transform.rotation.rotateVec(.{ 0, 1, 0 });
            break :up .{ up[0], up[1], up[2], 0 };
        },
    };
    current_frame.gpu_scene.copy(FrameData.GPUScene, (&scene_data)[0..1]);

    var cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32) = undefined;
    var cascades: Resources.GPUCascades = undefined;
    cascades.splits = .{ shadow_splits[0], shadow_splits[1], shadow_splits[2], 0 };
    for (0..Resources.shadow_cascade_count) |cascade_index| {
        const slice_near: f32 = if (cascade_index == 0) 0.05 else shadow_splits[cascade_index - 1];
        cascade_vps[cascade_index] = cascadeViewProj(camera_transform, fov_rad, aspect, slice_near, shadow_splits[cascade_index], light_dir);
        cascades.light_view_proj[cascade_index] = cascade_vps[cascade_index].d;
    }
    const frame_index = self.current_frame_inflight % self.frames.len;
    self.resources.writeCascades(frame_index, &cascades);

    for (info.world.entities.values()) |*entity| {
        const model = self.resources.getModelPtr(entity.model);
        if (model.isEmpty() or !model.isSkinned()) continue;
        const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
        for (skeleton.joint_matrices) |*matrices| {
            matrices.gpu.copy(nz.Mat4x4(f32), matrices.cpu);
        }
    }

    try renderShadowPass(self, cmd, info, cascade_vps);

    ext.vkCmdBeginRendering(cmd, &render_info);
    try renderWorldPass(self, cmd, current_frame, info);
    renderSkyPass(self, cmd, current_frame);
    renderParticlePass(self, cmd, current_frame, info);
    try renderDebugPass(self, cmd, current_frame, info);
    renderUiPass(self, cmd, current_frame, width, height);
    ext.vkCmdEndRendering(cmd);

    draw_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_READ_BIT);
}

const alpha_blend_eq: c.VkColorBlendEquationEXT = .{
    .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
    .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp = c.VK_BLEND_OP_ADD,
    .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .alphaBlendOp = c.VK_BLEND_OP_ADD,
};

fn setDefaultRenderState(self: *Vulkan, cmd: c.VkCommandBuffer, elapsed_time: f32) void {
    {
        const stages = [_]c.VkShaderStageFlagBits{
            c.VK_SHADER_STAGE_VERTEX_BIT,
            c.VK_SHADER_STAGE_FRAGMENT_BIT,
            c.VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
            c.VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
            c.VK_SHADER_STAGE_GEOMETRY_BIT,
        };

        const bound = [_]c.VkShaderEXT{ self.resources.shaderPtr(.{ .vert = .skinned }).handle, self.resources.shaderPtr(.{ .frag_normal = .mesh }).handle, null, null, null };
        ext.vkCmdBindShadersEXT(cmd, stages.len, &stages[0], &bound[0]);
    }

    const viewport: c.VkViewport = .{
        .width = @floatFromInt(self.swapchain.draw_image.extent.width),
        .height = @floatFromInt(self.swapchain.draw_image.extent.height),
        .maxDepth = 1,
    };
    const scissor: c.VkRect2D = .{
        .extent = .{
            .width = self.swapchain.draw_image.extent.width,
            .height = self.swapchain.draw_image.extent.height,
        },
    };

    ext.vkCmdSetViewportWithCountEXT(cmd, 1, &viewport);
    ext.vkCmdSetScissorWithCountEXT(cmd, 1, &scissor);

    // std.debug.print("time: {d}\n", .{self.elapsed_time});
    const tmp: i32 = @intFromFloat(elapsed_time);
    // std.debug.print("fixed-time: {d}\n", .{tmp});
    if (@mod(tmp, 2) == -1) {
        ext.vkCmdSetPolygonModeEXT(cmd, c.VK_POLYGON_MODE_LINE);
        c.vkCmdSetLineWidth(cmd, 1);
        ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_BACK_BIT);
    } else {
        ext.vkCmdSetPolygonModeEXT(cmd, c.VK_POLYGON_MODE_FILL);

        // c.vkCmdSetLineWidth(cmd, 1);
        ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_BACK_BIT);
    }
    ext.vkCmdSetFrontFaceEXT(cmd, c.VK_FRONT_FACE_COUNTER_CLOCKWISE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetRasterizerDiscardEnableEXT(cmd, c.VK_FALSE);

    ext.vkCmdSetRasterizationSamplesEXT(cmd, c.VK_SAMPLE_COUNT_1_BIT);
    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthBiasEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetStencilTestEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetPrimitiveRestartEnableEXT(cmd, c.VK_FALSE);

    const sample_mask: u32 = 0xFF;
    ext.vkCmdSetSampleMaskEXT(cmd, c.VK_SAMPLE_COUNT_1_BIT, &sample_mask);

    const color_blend_enables: c.VkBool32 = c.VK_FALSE;
    const color_blend_component_flags: c.VkColorComponentFlags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorWriteMaskEXT(cmd, 0, 1, &color_blend_component_flags);

    ext.vkCmdSetDepthBoundsTestEnable(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthClampEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetAlphaToOneEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetLogicOpEnableEXT(cmd, c.VK_FALSE);

    ext.vkCmdSetVertexInputEXT(cmd, 0, null, 0, null);
}

fn renderShadowPass(self: *Vulkan, cmd: c.VkCommandBuffer, info: *const Info, cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32)) !void {
    var shadow_barrier: Image.Barrier = .init(cmd, self.resources.shadow_image.vk_image, c.VK_IMAGE_ASPECT_DEPTH_BIT);
    shadow_barrier.src_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    shadow_barrier.src_access = c.VK_ACCESS_SHADER_READ_BIT;
    shadow_barrier.transition(
        c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    );
    var shadow_depth_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = self.resources.shadow_image.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{ .depthStencil = .{ .depth = 1, .stencil = 0 } },
    };
    var shadow_render_info: c.VkRenderingInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = Resources.shadow_map_size * Resources.shadow_cascade_count,
                .height = Resources.shadow_map_size,
            },
        },
        .layerCount = 1,
        .colorAttachmentCount = 0,
        .pDepthAttachment = &shadow_depth_attachment,
    };
    ext.vkCmdBeginRendering(cmd, &shadow_render_info);
    {
        const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const handles = [_]c.VkShaderEXT{ self.resources.shaderPtr(.{ .vert = .shadow_static }).handle, null };
        ext.vkCmdBindShadersEXT(cmd, 2, &stages[0], &handles[0]);
    }
    ext.vkCmdSetDepthBiasEnableEXT(cmd, c.VK_TRUE);
    c.vkCmdSetDepthBias(cmd, 0.0, 0.0, 3.0);
    for (cascade_vps, 0..) |cascade_vp, cascade_index| {
        const shadow_viewport: c.VkViewport = .{
            .x = @floatFromInt(cascade_index * Resources.shadow_map_size),
            .width = @floatFromInt(Resources.shadow_map_size),
            .height = @floatFromInt(Resources.shadow_map_size),
            .maxDepth = 1,
        };
        const shadow_scissor: c.VkRect2D = .{
            .offset = .{ .x = @intCast(cascade_index * Resources.shadow_map_size), .y = 0 },
            .extent = .{ .width = Resources.shadow_map_size, .height = Resources.shadow_map_size },
        };
        ext.vkCmdSetViewportWithCountEXT(cmd, 1, &shadow_viewport);
        ext.vkCmdSetScissorWithCountEXT(cmd, 1, &shadow_scissor);

        bindVertexShader(cmd, self.resources.shaderPtr(.{ .vert = .shadow_static }));
        for (info.world.entities.values()) |*entity| {
            const model = self.resources.getModelPtr(entity.model);
            if (model.isEmpty() or model.isSkinned()) continue;
            if (!cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(model.offset.toMat4x4()));
            try drawStatic(self, cmd, model, base_matrix);
        }
        bindVertexShader(cmd, self.resources.shaderPtr(.{ .vert = .shadow_skinned }));
        for (info.world.entities.values()) |*entity| {
            const model = self.resources.getModelPtr(entity.model);
            if (model.isEmpty() or !model.isSkinned()) continue;
            const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
            if (!cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(model.offset.toMat4x4()));
            try drawSkeletal(self, cmd, skeleton, base_matrix);
        }
    }
    ext.vkCmdEndRendering(cmd);
    shadow_barrier.transition(
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        c.VK_ACCESS_SHADER_READ_BIT,
    );
    ext.vkCmdSetDepthBiasEnableEXT(cmd, c.VK_FALSE);
    const full_viewport: c.VkViewport = .{
        .width = @floatFromInt(self.swapchain.draw_image.extent.width),
        .height = @floatFromInt(self.swapchain.draw_image.extent.height),
        .maxDepth = 1,
    };
    const full_scissor: c.VkRect2D = .{
        .extent = .{
            .width = self.swapchain.draw_image.extent.width,
            .height = self.swapchain.draw_image.extent.height,
        },
    };
    ext.vkCmdSetViewportWithCountEXT(cmd, 1, &full_viewport);
    ext.vkCmdSetScissorWithCountEXT(cmd, 1, &full_scissor);
}

fn renderWorldPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) !void {
    self.bindWorldDescriptors(cmd, current_frame);

    bindVertexShader(cmd, self.resources.shaderPtr(.{ .vert = .static }));
    bindFragmentShader(cmd, self.resources.shaderPtr(.{ .frag_normal = .mesh }));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.getModelPtr(entity.model);
        if (model.isEmpty() or model.isSkinned()) continue;
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawStatic(self, cmd, model, base_matrix);
    }

    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .planet) continue;
        const set = self.planet_chunks.getPtr(entity.id) orelse continue;
        const transform = entity.transform.toMat4x4();
        for (set.meshes.values()) |*mesh| try drawPlanetChunk(self, cmd, mesh, transform);
    }

    bindVertexShader(cmd, self.resources.shaderPtr(.{ .vert = .skinned }));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.getModelPtr(entity.model);
        if (model.isEmpty() or !model.isSkinned()) continue;
        const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawSkeletal(self, cmd, skeleton, base_matrix);
    }
}

fn renderSkyPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData) void {
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    {
        const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const handle = [_]c.VkShaderEXT{ self.resources.shaderPtr(.{ .vert = .sky }).handle, self.resources.shaderPtr(.{ .frag_normal = .sky }).handle };
        ext.vkCmdBindShadersEXT(cmd, 2, &stages[0], &handle[0]);
    }
    const sky_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = current_frame.gpu_scene.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.skybox_descriptor.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, sky_bindings.len, &sky_bindings[0]);
    {
        const sky_pipeline_layout_handle = self.resources.pipeline_layouts.get(.sky).handle;
        const buf_idx_0: u32 = 0;
        const off_0: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, sky_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, sky_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);
    }
    c.vkCmdDraw(cmd, 3, 1, 0, 0);

    self.bindWorldDescriptors(cmd, current_frame);
}

fn renderParticlePass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) void {
    const emitter_count: u32 = @intCast(@min(info.world.emitters.items.len, FrameData.max_emitters));
    if (emitter_count == 0) return;
    const emitters = info.world.emitters.items[0..emitter_count];
    const explosion_texture_index = self.resources.textureHandle(Resources.explosion_particle_name).index();
    const lightning_texture_index = self.resources.textureHandle(Resources.lightning_particle_name).index();

    var color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);

    const gpu_emitters: [*]FrameData.GPUEmitter = @ptrCast(@alignCast(current_frame.emitter_buffer.info.pMappedData));
    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;

    var first_instance: u32 = 0;
    for (std.enums.values(Shader.ParticleEffect)) |effect| {
        var effect_emitter_count: u32 = 0;
        for (emitters) |emitter| {
            if (emitter.effect != effect) continue;
            gpu_emitters[first_instance + effect_emitter_count] = .{
                .origin = emitter.origin,
                .spawn_time = emitter.spawn_time,
                .target = emitter.target,
            };
            effect_emitter_count += 1;
        }
        if (effect_emitter_count == 0) continue;

        const effect_spec = Shader.effectSpec(effect);
        bindVertexShader(cmd, self.resources.shaderPtr(.{ .vert_particle = effect }));
        bindFragmentShader(cmd, self.resources.shaderPtr(.{ .frag_particle = effect }));

        const push: Shader.WorldPushConstant = .{
            .model_matrix = nz.Mat4x4(f32).identity.d,
            .vertex_buffer_address = current_frame.emitter_buffer.getGPUAddress() +
                first_instance * @sizeOf(FrameData.GPUEmitter),
            .joint_matrices_address = 0,
            .texture_index = @intCast(switch (effect) {
                .explosion => explosion_texture_index,
                .lightning => lightning_texture_index,
            }),
            .particle_count = effect_spec.particle_count,
        };
        c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.WorldPushConstant), &push);
        c.vkCmdDraw(cmd, 6, effect_emitter_count * effect_spec.particle_count, 0, 0);
        first_instance += effect_emitter_count;
    }

    color_blend_enables = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
}

fn renderDebugPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) !void {
    if (!info.world.controller.debug_draw_colliders) return;

    const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
    const handles = [_]c.VkShaderEXT{ self.resources.shaderPtr(.{ .vert = .debug }).handle, self.resources.shaderPtr(.{ .frag_normal = .debug }).handle };
    ext.vkCmdBindShadersEXT(cmd, 2, &stages[0], &handles[0]);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST);
    c.vkCmdSetLineWidth(cmd, 1);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_FALSE);

    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
    const debug_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = current_frame.gpu_scene.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, 1, &debug_bindings[0]);
    const scene_buffer_index: u32 = 0;
    const scene_offset: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 0, 1, &scene_buffer_index, &scene_offset);

    const debug_vertices: [*]FrameData.DebugVertex = @ptrCast(@alignCast(current_frame.debug_vertex_buffer.info.pMappedData));
    var debug_vertex_count: u32 = 0;
    for (info.world.entities.values()) |*entity| {
        const collider_shape = (shared.entity.collider(entity.kind) orelse continue).shape;
        const first_vertex = debug_vertex_count;
        switch (collider_shape) {
            .capsule => |capsule| try appendCapsuleLines(debug_vertices, &debug_vertex_count, capsule.half_heigth, capsule.radius),
            .box => |box| try appendBoxLines(
                debug_vertices,
                &debug_vertex_count,
                box,
            ),
        }
        var collider_transform = entity.transform;
        collider_transform.scale = @splat(1);
        var push: Shader.WorldPushConstant = .{
            .vertex_buffer_address = current_frame.debug_vertex_buffer.getGPUAddress(),
            .model_matrix = collider_transform.toMat4x4().d,
            .joint_matrices_address = 0,
            .texture_index = 0,
        };
        c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.WorldPushConstant), &push);
        c.vkCmdDraw(cmd, debug_vertex_count - first_vertex, 1, first_vertex, 0);
    }
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
}

fn renderUiPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, width: f32, height: f32) void {
    current_frame.ui_vertex_buffer.copy(Ui.Quad, self.ui.quads.items);
    const stages_ui = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const bounds_ui = [_]c.VkShaderEXT{
        self.resources.shaderPtr(.{ .vert = .ui }).handle,
        self.resources.shaderPtr(.{ .frag_normal = .ui }).handle,
    };

    ext.vkCmdBindShadersEXT(cmd, 2, &stages_ui[0], &bounds_ui[0]);

    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_FALSE);
    const color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);
    const ui_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.texture_descriptor_buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, 1, &ui_bindings[0]);

    const ui_pipeline_layout_handle = self.resources.pipeline_layouts.get(.ui).handle;
    const buf_idx_0: u32 = 0;
    const off_0: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ui_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);

    var push: Shader.UiPushConstant = .{
        .vertex_buffer_address = current_frame.ui_vertex_buffer.getGPUAddress(),
        .screnn_size = .{ width, height },
    };
    c.vkCmdPushConstants(cmd, ui_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.UiPushConstant), &push);
    c.vkCmdBindIndexBuffer(cmd, self.ui.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(cmd, @as(u32, @intCast(self.ui.quads.items.len * 6)), 1, 0, 0, 0);
}

fn drawStatic(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    model: *const Model,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (model.surfaces.items) |surface| {
        const mesh = self.resources.getMeshPtr(surface.mesh_id);
        const surface_matrix = top_matrix.mul(surface.model_matrix);
        var push: Shader.WorldPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = surface_matrix.d,
            .joint_matrices_address = 0,
            .texture_index = 0,
        };
        try emitNode(self, cmd, mesh, &push);
    }
}

fn drawPlanetChunk(self: *Vulkan, cmd: c.VkCommandBuffer, mesh: *const Mesh, transform: nz.Mat4x4(f32)) !void {
    var push: Shader.WorldPushConstant = .{
        .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
        .model_matrix = transform.d,
        .joint_matrices_address = 0,
        .texture_index = 0,
    };
    try emitNode(self, cmd, mesh, &push);
}

fn drawSkeletal(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    skeleton: *const SkeletonInstance,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (skeleton.nodes) |node| {
        const mesh_id = node.mesh_id orelse continue;
        const mesh = self.resources.getMeshPtr(mesh_id);
        var push: Shader.WorldPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = if (node.skin_id != null) top_matrix.d else top_matrix.mul(node.model_matrix).d,
            .joint_matrices_address = if (node.skin_id) |skin_index|
                skeleton.joint_matrices[skin_index].gpu.getGPUAddress()
            else
                self.resources.identity_joint_buffer.getGPUAddress(),
            .texture_index = 0,
        };
        try emitNode(self, cmd, mesh, &push);
    }
}

const debug_collider_color: [4]f32 = .{ 0, 1, 0, 1 };
const debug_circle_segments = 16;

fn appendDebugLine(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, from: nz.Vec3(f32), to: nz.Vec3(f32)) !void {
    if (vertex_count.* + 2 > FrameData.max_debug_vertices) return error.DebugVertexBufferFull;
    vertices[vertex_count.*] = .{ .position = .{ from[0], from[1], from[2], 1 }, .color = debug_collider_color };
    vertices[vertex_count.* + 1] = .{ .position = .{ to[0], to[1], to[2], 1 }, .color = debug_collider_color };
    vertex_count.* += 2;
}

fn appendCapsuleLines(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, half_heigth: f32, radius: f32) !void {
    for (0..debug_circle_segments) |segment| {
        const angle_start = std.math.tau * @as(f32, @floatFromInt(segment)) / debug_circle_segments;
        const angle_end = std.math.tau * @as(f32, @floatFromInt(segment + 1)) / debug_circle_segments;
        for ([2]f32{ -half_heigth, half_heigth }) |ring_y| {
            try appendDebugLine(
                vertices,
                vertex_count,
                .{ radius * @cos(angle_start), ring_y, radius * @sin(angle_start) },
                .{ radius * @cos(angle_end), ring_y, radius * @sin(angle_end) },
            );
        }
    }
    for (0..4) |quarter| {
        const angle = std.math.tau * @as(f32, @floatFromInt(quarter)) / 4;
        try appendDebugLine(
            vertices,
            vertex_count,
            .{ radius * @cos(angle), -half_heigth, radius * @sin(angle) },
            .{ radius * @cos(angle), half_heigth, radius * @sin(angle) },
        );
    }
    const arc_segments = debug_circle_segments / 2;
    for (0..arc_segments) |segment| {
        const angle_start = std.math.pi * @as(f32, @floatFromInt(segment)) / arc_segments;
        const angle_end = std.math.pi * @as(f32, @floatFromInt(segment + 1)) / arc_segments;
        for ([2]f32{ 1, -1 }) |cap_direction| {
            const cap_y = cap_direction * half_heigth;
            try appendDebugLine(
                vertices,
                vertex_count,
                .{ radius * @cos(angle_start), cap_y + cap_direction * radius * @sin(angle_start), 0 },
                .{ radius * @cos(angle_end), cap_y + cap_direction * radius * @sin(angle_end), 0 },
            );
            try appendDebugLine(
                vertices,
                vertex_count,
                .{ 0, cap_y + cap_direction * radius * @sin(angle_start), radius * @cos(angle_start) },
                .{ 0, cap_y + cap_direction * radius * @sin(angle_end), radius * @cos(angle_end) },
            );
        }
    }
}

fn appendBoxLines(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, box: shared.entity.ColliderShape.HalfBoxExtent) !void {
    const bottom_corners = [4]nz.Vec3(f32){
        .{ -box.x, -box.y, -box.z },
        .{ box.x, -box.y, -box.z },
        .{ box.x, -box.y, box.z },
        .{ -box.x, -box.y, box.z },
    };
    var top_corners = bottom_corners;
    for (&top_corners) |*corner| corner[1] = box.y;

    for (0..4) |corner_index| {
        const next_corner_index = (corner_index + 1) % 4;
        try appendDebugLine(vertices, vertex_count, bottom_corners[corner_index], bottom_corners[next_corner_index]);
        try appendDebugLine(vertices, vertex_count, top_corners[corner_index], top_corners[next_corner_index]);
        try appendDebugLine(vertices, vertex_count, bottom_corners[corner_index], top_corners[corner_index]);
    }
}

fn bindVertexShader(cmd: c.VkCommandBuffer, shader: *Shader) void {
    const stage = [_]c.VkShaderStageFlagBits{c.VK_SHADER_STAGE_VERTEX_BIT};
    const handle = [_]c.VkShaderEXT{shader.handle};
    ext.vkCmdBindShadersEXT(cmd, 1, &stage[0], &handle[0]);
}
fn bindFragmentShader(cmd: c.VkCommandBuffer, shader: *Shader) void {
    const stage = [_]c.VkShaderStageFlagBits{c.VK_SHADER_STAGE_FRAGMENT_BIT};
    const handle = [_]c.VkShaderEXT{shader.handle};
    ext.vkCmdBindShadersEXT(cmd, 1, &stage[0], &handle[0]);
}

fn emitNode(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    mesh: *const Mesh,
    push: *Shader.WorldPushConstant,
) !void {
    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
    c.vkCmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    for (mesh.surfaces.items) |surface| {
        push.texture_index = @intFromEnum(surface.texture);
        c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.WorldPushConstant), push);
        c.vkCmdDrawIndexed(cmd, @intCast(surface.index_count), 1, surface.index_start, 0, 0);
    }
}

fn bindWorldDescriptors(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData) void {
    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
    const shadow_descriptor_buffer = &self.resources.shadow_descriptor_buffers[self.current_frame_inflight % self.frames.len];
    const world_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = current_frame.gpu_scene.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.texture_descriptor_buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = shadow_descriptor_buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, world_bindings.len, &world_bindings[0]);
    const buf_idx_0: u32 = 0;
    const off_0: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
    const buf_idx_1: u32 = 1;
    const off_1: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);
    const buf_idx_2: u32 = 2;
    const off_2: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 2, 1, &buf_idx_2, &off_2);
}

pub fn resize(self: *Vulkan, gpa: std.mem.Allocator, width: u32, height: u32) !void {
    try self.swapchain.recreate(
        gpa,
        self.vma,
        self.physical_device,
        self.device,
        self.surface,
        width,
        height,
    );
    self.ui.screen_heigth = @floatFromInt(self.swapchain.extent.height);
    self.ui.screen_width = @floatFromInt(self.swapchain.extent.width);
}

pub fn drainRenderCommands(self: *Vulkan, gpa: std.mem.Allocator, world: *World, timer_io: std.Io) !void {
    try self.collectPlanetChunkJob(gpa, world);
    for (world.render_outbox.items) |command| switch (command) {
        .entity_spawned => |spawned| {
            if (spawned.kind == .planet) continue;
            const entity = world.getPtr(spawned.id) orelse continue;
            entity.model = self.resources.modelHandle(shared.entity.modelSpec(spawned.kind).key);
            try self.ensureSkeleton(gpa, spawned.id, spawned.kind, entity.model);
        },
        .entity_despawned => |id| {
            self.removeSkeleton(gpa, id);
            self.removePlanetChunks(gpa, id);
        },
        .planet_spawned => |planet| try self.buildPlanet(gpa, planet.id, planet.radius),
    };
    world.render_outbox.clearRetainingCapacity();
    try self.updatePlanetChunks(gpa, world, timer_io);
}

fn buildPlanet(self: *Vulkan, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32) !void {
    self.removePlanetChunks(gpa, id);
    try self.planet_chunks.put(id, .{ .radius = radius, .center = null, .reach = 0, .meshes = .empty });
}

fn updatePlanetChunks(self: *Vulkan, gpa: std.mem.Allocator, world: *World, timer_io: std.Io) !void {
    if (self.planet_chunk_job != null) return;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .planet) continue;
        const set = self.planet_chunks.getPtr(entity.id) orelse continue;
        const center = planetChunkCenter(world, entity);
        const reach = planetChunkReach(world, set.radius);
        if (set.center) |known| {
            if (set.radius <= @as(u32, @intCast(shared.planet.chunk_dim))) continue;
            if (std.meta.eql(known, center) and set.reach == reach) continue;
        }
        set.center = center;
        set.reach = reach;
        try self.startPlanetChunkJob(gpa, timer_io, entity.id, set.radius, center, reach, set.meshes.keys());
        return;
    }
}

fn startPlanetChunkJob(self: *Vulkan, gpa: std.mem.Allocator, io: std.Io, id: shared.entity.Id, radius: u32, center: nz.Vec3(i32), reach: i32, existing_coords: []const nz.Vec3(i32)) !void {
    const state = try gpa.create(PlanetChunkJobState);
    errdefer gpa.destroy(state);
    const existing = try gpa.dupe(nz.Vec3(i32), existing_coords);
    errdefer gpa.free(existing);
    state.* = .{ .gpa = gpa, .io = io, .id = id, .radius = radius, .center = center, .reach = reach, .existing = existing };
    self.planet_chunk_job = .{ .thread = try std.Thread.spawn(.{}, generatePlanetChunkJob, .{state}), .state = state };
}

fn collectPlanetChunkJob(self: *Vulkan, gpa: std.mem.Allocator, world: *World) !void {
    const job = self.planet_chunk_job orelse return;
    try job.state.mutex.lock(job.state.io);
    const done = job.state.done;
    job.state.mutex.unlock(job.state.io);
    if (!done) return;
    job.thread.join();
    self.planet_chunk_job = null;
    defer {
        deinitPlanetChunkJob(job.state);
        gpa.destroy(job.state);
    }
    if (job.state.err) |err| return err;
    const set = self.planet_chunks.getPtr(job.state.id) orelse return;
    const entity = world.getPtr(job.state.id) orelse return;

    var evicted: usize = 0;
    if (set.radius > @as(u32, @intCast(shared.planet.chunk_dim))) {
        const live_center = planetChunkCenter(world, entity);
        const live_reach = planetChunkReach(world, set.radius);
        const window_min = live_center - @as(nz.Vec3(i32), @splat(live_reach));
        const window_max = live_center + @as(nz.Vec3(i32), @splat(live_reach));
        var any_outside = false;
        for (set.meshes.keys()) |coord| {
            if (@reduce(.Or, coord < window_min) or @reduce(.Or, coord > window_max)) {
                any_outside = true;
                break;
            }
        }
        if (any_outside) {
            check(c.vkDeviceWaitIdle(self.device.handle)) catch unreachable;
            var mesh_index: usize = set.meshes.count();
            while (mesh_index > 0) {
                mesh_index -= 1;
                const coord = set.meshes.keys()[mesh_index];
                if (@reduce(.Or, coord < window_min) or @reduce(.Or, coord > window_max)) {
                    set.meshes.values()[mesh_index].deinit(gpa, self.vma);
                    set.meshes.swapRemoveAt(mesh_index);
                    evicted += 1;
                }
            }
        }
        if (!std.meta.eql(live_center, job.state.center) or live_reach != job.state.reach) set.center = null;
    }
    for (job.state.chunks.items) |*cpu_chunk| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}-{d}", .{ @intFromEnum(job.state.id), cpu_chunk.coord[0], cpu_chunk.coord[1], cpu_chunk.coord[2] });
        const mesh = try Mesh.init(gpa, self.vma, name, self.device, Mesh.StaticVertex, cpu_chunk.vertices, cpu_chunk.indices, &.{.{ .index_start = 0, .index_count = @intCast(cpu_chunk.indices.len), .texture = .blank }});
        try set.meshes.put(gpa, cpu_chunk.coord, mesh);
    }
    std.log.debug("planet chunks: center={any}, added={d}, evicted={d}, active={d}", .{ job.state.center, job.state.chunks.items.len, evicted, set.meshes.count() });
}

fn generatePlanetChunkJob(state: *PlanetChunkJobState) void {
    generatePlanetCpuChunks(state) catch |err| {
        state.err = err;
    };
    state.mutex.lock(state.io) catch unreachable;
    state.done = true;
    state.mutex.unlock(state.io);
}

fn generatePlanetCpuChunks(state: *PlanetChunkJobState) !void {
    const small = state.radius <= @as(u32, @intCast(shared.planet.chunk_dim));
    const clamp: ?shared.planet.ChunkBox = if (small) null else .{
        .min = state.center - @as(nz.Vec3(i32), @splat(state.reach)),
        .max = state.center + @as(nz.Vec3(i32), @splat(state.reach)),
    };
    var timings: shared.planet.StageTimings = .init(state.io);
    const build_start = std.Io.Clock.Timestamp.now(state.io, .awake);
    const coords = try shared.planet.surfaceChunks(state.gpa, state.radius, clamp);
    defer state.gpa.free(coords);
    for (coords) |coord| {
        var already_built = false;
        for (state.existing) |existing_coord| {
            if (std.meta.eql(existing_coord, coord)) {
                already_built = true;
                break;
            }
        }
        if (already_built) continue;
        const planet = try shared.planet.Planet(.renderable).initChunk(state.gpa, state.radius, coord, &timings);
        if (planet.indices.len == 0) {
            planet.deinit(state.gpa);
            continue;
        }
        try state.chunks.append(state.gpa, .{ .coord = coord, .vertices = planet.vertices, .indices = planet.indices });
    }
    timings.log(state.chunks.items.len, timings.elapsedNs(build_start));
}

fn deinitPlanetChunkJob(state: *PlanetChunkJobState) void {
    for (state.chunks.items) |chunk| {
        state.gpa.free(chunk.vertices);
        state.gpa.free(chunk.indices);
    }
    state.chunks.deinit(state.gpa);
    state.gpa.free(state.existing);
}

fn removePlanetChunks(self: *Vulkan, gpa: std.mem.Allocator, id: shared.entity.Id) void {
    if (self.planet_chunks.fetchRemove(id)) |entry| {
        check(c.vkDeviceWaitIdle(self.device.handle)) catch unreachable;
        var set = entry.value;
        deinitPlanetChunkMap(&set.meshes, gpa, self.vma);
    }
}

fn planetChunkReach(world: *World, radius: u32) i32 {
    const range = shared.planet.chunkRange(radius);
    return std.math.clamp(world.chunk_view_distance, 1, range.max - range.min + 1);
}

fn planetChunkCenter(world: *World, planet: *const World.Entity) nz.Vec3(i32) {
    const position = if (world.controller.free_camera) world.camera.transform.position else if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position;
    const local = position - planet.transform.position;
    const chunk_size: f32 = @floatFromInt(shared.planet.chunk_dim);
    return .{
        @intFromFloat(@floor(local[0] / (planet.transform.scale[0] * chunk_size))),
        @intFromFloat(@floor(local[1] / (planet.transform.scale[1] * chunk_size))),
        @intFromFloat(@floor(local[2] / (planet.transform.scale[2] * chunk_size))),
    };
}

fn deinitPlanetChunkMap(chunks: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Mesh), gpa: std.mem.Allocator, vma: Vma) void {
    for (chunks.values()) |*mesh| mesh.deinit(gpa, vma);
    chunks.deinit(gpa);
}

fn ensureSkeleton(self: *Vulkan, gpa: std.mem.Allocator, entity_id: shared.entity.Id, entity_kind: shared.entity.Kind, model_handle: Model.Handle) !void {
    if (self.skeletons.contains(entity_id)) return;
    const model = self.resources.getModelPtr(model_handle);
    if (model.isEmpty() and entity_kind.expectsModel()) {
        std.debug.panic("no model registered for {s}", .{@tagName(entity_kind)});
    }
    if (!model.isSkinned()) return; // static/modelless: no skeleton
    try self.skeletons.put(entity_id, try .init(gpa, self.vma, self.device, model));
}

fn removeSkeleton(self: *Vulkan, gpa: std.mem.Allocator, entity_id: shared.entity.Id) void {
    if (self.skeletons.fetchRemove(entity_id)) |kv| {
        var skeleton = kv.value;
        skeleton.deinit(gpa, self.vma);
    }
}

fn clearSkeletons(self: *Vulkan, gpa: std.mem.Allocator) void {
    var it = self.skeletons.valueIterator();
    while (it.next()) |skeleton| skeleton.deinit(gpa, self.vma);
    self.skeletons.clearRetainingCapacity();
}

fn getViewMatrix(transform: *const nz.Transform3D(f32)) nz.Mat4x4(f32) {
    const inv_rotation = transform.rotation.conjugate().toMat4x4();
    const inv_translation = nz.Mat4x4(f32).translate(-transform.position);

    return inv_rotation.mul(inv_translation);
}

fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    const f = 1.0 / std.math.tan(fovy_rad / 2.0);
    return .new(.{
        f / aspect, 0, 0, 0,
        0, -f, 0,                           0, // flip Y for Vulkan
        0, 0,  far / (near - far),          -1,
        0, 0,  (far * near) / (near - far), 0,
    });
}

fn cascadeViewProj(camera: nz.Transform3D(f32), fov_rad: f32, aspect: f32, slice_near: f32, slice_far: f32, light_dir: nz.Vec3(f32)) nz.Mat4x4(f32) {
    const forward = camera.rotation.rotateVec(.{ 0, 0, -1 });
    const right = camera.rotation.rotateVec(.{ 1, 0, 0 });
    const up = camera.rotation.rotateVec(.{ 0, 1, 0 });
    const tan_half_fov = @tan(fov_rad * 0.5);

    var corners: [8]nz.Vec3(f32) = undefined;
    for ([2]f32{ slice_near, slice_far }, 0..) |plane_distance, plane| {
        const half_height = plane_distance * tan_half_fov;
        const half_width = half_height * aspect;
        const plane_center = camera.position + nz.vec.scale(forward, plane_distance);
        for (0..4) |corner| {
            const sign_x: f32 = if (corner & 1 == 0) -1 else 1;
            const sign_y: f32 = if (corner & 2 == 0) -1 else 1;
            corners[plane * 4 + corner] = plane_center +
                nz.vec.scale(right, sign_x * half_width) +
                nz.vec.scale(up, sign_y * half_height);
        }
    }

    var center: nz.Vec3(f32) = .{ 0, 0, 0 };
    for (corners) |corner| center += corner;
    center = nz.vec.scale(center, 1.0 / 8.0);
    var radius: f32 = 0;
    for (corners) |corner| radius = @max(radius, nz.vec.length(corner - center));

    const normalized_light = nz.vec.normalize(light_dir);
    const up_reference: nz.Vec3(f32) = if (@abs(normalized_light[1]) > 0.99) .{ 0, 0, 1 } else .{ 0, 1, 0 };
    const light_view = nz.Mat4x4(f32).lookAt(.{ 0, 0, 0 }, -normalized_light, up_reference);

    const center_light = light_view.mulVec4(.{ center[0], center[1], center[2], 1 });
    const texel_size = radius * 2.0 / @as(f32, @floatFromInt(Resources.shadow_map_size));
    const snapped_x = @floor(center_light[0] / texel_size) * texel_size;
    const snapped_y = @floor(center_light[1] / texel_size) * texel_size;

    const caster_pad: f32 = 80; // room behind the slice for off-screen casters
    const proj = shadowOrtho(
        snapped_x - radius,
        snapped_x + radius,
        snapped_y - radius,
        snapped_y + radius,
        -(center_light[2] + radius + caster_pad),
        -(center_light[2] - radius),
    );
    return proj.mul(light_view);
}

const shadow_caster_radius: f32 = 16;

fn cascadeContains(cascade_vp: *const nz.Mat4x4(f32), position: nz.Vec3(f32)) bool {
    const clip = cascade_vp.mulVec4(.{ position[0], position[1], position[2], 1 });
    const margin_x = shadow_caster_radius * @abs(cascade_vp.d[0]);
    const margin_y = shadow_caster_radius * @abs(cascade_vp.d[5]);
    const margin_z = shadow_caster_radius * @abs(cascade_vp.d[10]);
    return @abs(clip[0]) <= 1 + margin_x and
        @abs(clip[1]) <= 1 + margin_y and
        clip[2] >= -margin_z and clip[2] <= 1 + margin_z;
}

fn shadowOrtho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    return .new(.{
        2.0 / (right - left),             0,                               0,                   0,
        0,                                -2.0 / (top - bottom),           0,                   0,
        0,                                0,                               1.0 / (near - far),  0,
        -(right + left) / (right - left), (top + bottom) / (top - bottom), near / (near - far), 1,
    });
}

fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    return .new(.{
        2.0 / (right - left),             0.0,                              0.0,                          0.0,
        0.0,                              2.0 / (top - bottom),             0.0,                          0.0,
        0.0,                              0.0,                              -2.0 / (far - near),          0.0,
        -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1.0,
    });
}
