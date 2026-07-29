const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const nz = shared.numz;
const AssetServer = @import("../AssetServer.zig");
const ModelLoader = @import("loader/ModelLoader.zig");
const TextureTable = @import("loader/TextureTable.zig");
const system = @import("../System.zig");
const World = system.World;
const Instance = @import("Vulkan/Instance.zig");
const DebugMessenger = @import("Vulkan/DebugMessenger.zig");
const PhysicalDevice = @import("Vulkan/device.zig").Physical;
const Device = @import("Vulkan/device.zig").Logical;
const Mesh = @import("Vulkan/Mesh.zig");
const Node = @import("../asset/Node.zig");
const Buffer = @import("Vulkan/Buffer.zig");
const AnimationInstance = @import("../asset/AnimationInstance.zig");
const AnimationClip = @import("../asset/AnimationClip.zig");
const Vma = @import("Vulkan/Vma.zig");
const Swapchain = @import("Vulkan/Swapchain.zig");
const FrameData = @import("Vulkan/FrameData.zig");
const Surface = @import("Vulkan/Surface.zig");
const Image = @import("Vulkan/Image.zig");
const Resources = @import("Vulkan/Resources.zig");
const Planet = @import("Planet.zig");
const Shader = @import("Vulkan/Shader.zig");
const Emitter = @import("../system/Emitter.zig");
const Ui = @import("../Ui.zig");
const procs = @import("Vulkan/procs.zig");
const ext = procs.device.ProcTable;
const tracy = @import("ztracy");

const check = @import("Vulkan/utils.zig").check;

pub const Model = @import("../asset/Model.zig");
pub const Info = system.Info;
pub const c = @import("vulkan");
const shadow_splits = [Resources.shadow_cascade_count]f32{ 16, 48, 120 };

gpa: std.mem.Allocator,

instance: Instance,
debug_messenger: ?DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
vma: Vma,
swapchain: Swapchain,
resources: *Resources,
joint_buffers: std.AutoHashMap(shared.entity.Id, []Buffer),
planet: Planet,
current_frame_inflight: u32 = 0,
frames: [FrameData.max_frames_inflight]FrameData,

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
    self.joint_buffers = .init(gpa);
    self.planet = .init();
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

    self.resources = try .init(gpa, asset_server, self.vma, self.physical_device, self.device);

    try asset_server.load();
    self.resources.shader_loader.verifyAllKindsLoaded();

    return self;
}

pub fn deinit(self: *Vulkan, gpa: std.mem.Allocator) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};

    self.resources.deinit(gpa, self.vma, self.device);

    self.clearSkeletons(gpa);
    self.joint_buffers.deinit();
    self.planet.deinit(gpa, self.vma);

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

pub fn update(self: *Vulkan, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), ui: *const Ui) !void {
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

    try render(self, cmd_buffer, current_frame, info, instances, ui);

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

pub fn render(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), ui: *const Ui) !void {
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

    setDefaultRenderState(self, cmd);

    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    const aspect: f32 = width / height;

    const camera_transform = info.world.camera.transform;
    const view_matrix = getViewMatrix(&camera_transform);
    const fov_rad: f32 = info.world.camera.fov_rad;
    var proj = perspective(fov_rad, aspect, 0.01, 1000);
    const proj_view = proj.mul(view_matrix);

    const light_time = info.elapsed_time * 0.01 + 0.9;
    const light_dir = nz.vec.normalize(@as(nz.Vec3(f32), .{ @cos(light_time), @sin(light_time), 0.3 }));
    var scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_proj_rotation = camera_transform.rotation.toMat4x4().mul(proj.inverse()).d,
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

    var joint_upload_iterator = self.joint_buffers.iterator();
    while (joint_upload_iterator.next()) |entry| {
        const instance = instances.getPtr(entry.key_ptr.*) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        for (skeleton.joint_matrices, entry.value_ptr.*) |cpu_matrices, *joint_buffer| {
            joint_buffer.copy(nz.Mat4x4(f32), cpu_matrices);
        }
    }

    try renderShadowPass(self, cmd, info, instances, cascade_vps);

    const particle_batches = packEmitters(current_frame, info);
    dispatchParticles(self, cmd, current_frame, info, particle_batches);

    ext.vkCmdBeginRendering(cmd, &render_info);
    try renderWorldPass(self, cmd, current_frame, info, instances);
    renderSkyPass(self, cmd, current_frame);
    renderParticlePass(self, cmd, current_frame, info, particle_batches);
    try renderDebugPass(self, cmd, current_frame, info);
    renderUiPass(self, cmd, current_frame, ui, width, height);
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

fn setDefaultRenderState(self: *Vulkan, cmd: c.VkCommandBuffer) void {
    {
        const stages = [_]c.VkShaderStageFlagBits{
            c.VK_SHADER_STAGE_VERTEX_BIT,
            c.VK_SHADER_STAGE_FRAGMENT_BIT,
            c.VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
            c.VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
            c.VK_SHADER_STAGE_GEOMETRY_BIT,
        };

        const bound = [_]c.VkShaderEXT{ self.resources.shader_loader.shaderPtr(.skinned_vert, .vert).handle, self.resources.shader_loader.shaderPtr(.mesh_frag, .frag).handle, null, null, null };
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
    // const tmp: i32 = @intFromFloat(elapsed_time);
    // std.debug.print("fixed-time: {d}\n", .{tmp});
    if (false) {
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

fn renderShadowPass(self: *Vulkan, cmd: c.VkCommandBuffer, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32)) !void {
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
        const handles = [_]c.VkShaderEXT{ self.resources.shader_loader.shaderPtr(.shadow_static_vert, .vert).handle, null };
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

        bindVertexShader(cmd, self.resources.shader_loader.shaderPtr(.shadow_static_vert, .vert));
        for (info.world.entities.values()) |*entity| {
            if (!cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const offset = shared.entity.spec(entity.kind).model.offset;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(offset.toMat4x4()));
            try drawStatic(self, cmd, entity.model_handle, base_matrix);
        }
        bindVertexShader(cmd, self.resources.shader_loader.shaderPtr(.shadow_skinned_vert, .vert));
        for (info.world.entities.values()) |*entity| {
            const instance = instances.getPtr(entity.id) orelse continue;
            const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
            const entry = fileEntry(self, entity.model_handle) orelse continue;
            const joint_buffers = self.joint_buffers.getPtr(entity.id) orelse continue;
            if (!cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const offset = shared.entity.spec(entity.kind).model.offset;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(offset.toMat4x4()));
            try drawSkinned(self, cmd, skeleton, entry.meshes, joint_buffers.*, base_matrix);
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

fn renderWorldPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    self.bindWorldDescriptors(cmd, current_frame, self.resources.pipeline_layouts.get(.world).handle);

    bindVertexShader(cmd, self.resources.shader_loader.shaderPtr(.static_vert, .vert));
    bindFragmentShader(cmd, self.resources.shader_loader.shaderPtr(.mesh_frag, .frag));
    for (info.world.entities.values()) |*entity| {
        const offset = shared.entity.spec(entity.kind).model.offset;
        const base_matrix = entity.transform.toMat4x4().mul(offset.toMat4x4());
        try drawStatic(self, cmd, entity.model_handle, base_matrix);
    }

    if (info.world.getPtr(self.planet.planet_id)) |planet| {
        const transform = planet.transform.toMat4x4();
        for (self.planet.meshes.values()) |*mesh| try drawPlanetChunk(self, cmd, mesh, transform);
    }

    bindVertexShader(cmd, self.resources.shader_loader.shaderPtr(.skinned_vert, .vert));
    for (info.world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        const entry = fileEntry(self, entity.model_handle) orelse continue;
        const joint_buffers = self.joint_buffers.getPtr(entity.id) orelse continue;
        const offset = shared.entity.spec(entity.kind).model.offset;
        const base_matrix = entity.transform.toMat4x4().mul(offset.toMat4x4());
        try drawSkinned(self, cmd, skeleton, entry.meshes, joint_buffers.*, base_matrix);
    }
}

fn renderSkyPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData) void {
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    {
        const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const handle = [_]c.VkShaderEXT{ self.resources.shader_loader.shaderPtr(.sky_vert, .vert).handle, self.resources.shader_loader.shaderPtr(.sky_frag, .frag).handle };
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
            .address = self.resources.texture_table.skybox_descriptor.getGPUAddress(),
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

    self.bindWorldDescriptors(cmd, current_frame, self.resources.pipeline_layouts.get(.world).handle);
}

const particle_workgroup_size: u32 = 64;

const ParticleBatch = struct { first_emitter: u32, emitter_count: u32 };

/// Compacts the live emitters into this frame's emitter buffer, grouped per effect.
/// Runs before rendering opens so the compute stage can read the same packing the
/// draws will. The slot each emitter owns rides along in GPUEmitter.slot, so
/// compaction never moves a particle's place in the persistent particle buffer.
fn packEmitters(current_frame: *const FrameData, info: *const Info) std.EnumArray(Shader.Kind, ParticleBatch) {
    const gpu_emitters: [*]FrameData.GPUEmitter = @ptrCast(@alignCast(current_frame.emitter_buffer.info.pMappedData));
    var batches: std.EnumArray(Shader.Kind, ParticleBatch) = .initFill(.{ .first_emitter = 0, .emitter_count = 0 });
    var first_emitter: u32 = 0;
    for (std.enums.values(Shader.Kind)) |effect| {
        if (Shader.get(effect).particle == null) continue;
        var emitter_count: u32 = 0;
        for (&info.world.emitters, 0..) |emitter, slot| {
            if (emitter.effect != effect) continue;
            if (!emitter.alive(info.elapsed_time)) continue;
            gpu_emitters[first_emitter + emitter_count] = .{
                .origin = emitter.origin,
                .spawn_time = emitter.spawn_time,
                .target = emitter.target,
                .slot = @intCast(slot),
            };
            emitter_count += 1;
        }
        batches.set(effect, .{ .first_emitter = first_emitter, .emitter_count = emitter_count });
        first_emitter += emitter_count;
    }
    return batches;
}

fn particlePushConstant(self: *Vulkan, current_frame: *const FrameData, info: *const Info, effect: Shader.Kind, batch: ParticleBatch) Shader.ParticlePushConstant {
    const particle_info = Shader.particleInfo(effect);
    return .{
        .particle_buffer_address = self.resources.particle_buffer.getGPUAddress(),
        .emitter_buffer_address = current_frame.emitter_buffer.getGPUAddress() +
            batch.first_emitter * @sizeOf(FrameData.GPUEmitter),
        .elapsed_time = info.elapsed_time,
        .delta_time = info.delta_time,
        .particle_count = particle_info.particle_count,
        .particle_stride = Emitter.max_particles_per_effect,
        .emitter_count = batch.emitter_count,
        .texture_index = @intCast(self.resources.texture_table.handle(particle_info.texture_name).index()),
    };
}

fn memoryBarrier(
    cmd: c.VkCommandBuffer,
    src_stage: c.VkPipelineStageFlags2,
    src_access: c.VkAccessFlags2,
    dst_stage: c.VkPipelineStageFlags2,
    dst_access: c.VkAccessFlags2,
) void {
    const barrier: c.VkMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
        .srcStageMask = src_stage,
        .srcAccessMask = src_access,
        .dstStageMask = dst_stage,
        .dstAccessMask = dst_access,
    };
    const dependency: c.VkDependencyInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .memoryBarrierCount = 1,
        .pMemoryBarriers = &barrier,
    };
    c.vkCmdPipelineBarrier2(cmd, &dependency);
}

/// Must run outside a dynamic rendering scope -- binding a compute shader inside one
/// is illegal. Every effect that declares a `.comp` stage simulates here; the rest
/// stay closed-form in their vertex shader.
fn dispatchParticles(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info, batches: std.EnumArray(Shader.Kind, ParticleBatch)) void {
    // covers last frame's vertex reads (WAR) and the previous frame's compute writes (WAW)
    memoryBarrier(
        cmd,
        c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT | c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT,
        c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT | c.VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
        c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
        c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT | c.VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
    );

    const particle_pipeline_layout_handle = self.resources.pipeline_layouts.get(.particle).handle;
    for (std.enums.values(Shader.Kind)) |effect| {
        if (!Shader.hasStage(effect, .comp)) continue;
        const batch = batches.get(effect);
        if (batch.emitter_count == 0) continue;

        const stage = [_]c.VkShaderStageFlagBits{c.VK_SHADER_STAGE_COMPUTE_BIT};
        const handle = [_]c.VkShaderEXT{self.resources.shader_loader.shaderPtr(effect, .comp).handle};
        ext.vkCmdBindShadersEXT(cmd, 1, &stage[0], &handle[0]);

        const push = particlePushConstant(self, current_frame, info, effect, batch);
        c.vkCmdPushConstants(cmd, particle_pipeline_layout_handle, Shader.pushConstantStages(.particle), 0, @sizeOf(Shader.ParticlePushConstant), &push);
        const thread_count = batch.emitter_count * push.particle_count;
        c.vkCmdDispatch(cmd, (thread_count + particle_workgroup_size - 1) / particle_workgroup_size, 1, 1);
    }

    memoryBarrier(
        cmd,
        c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
        c.VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
        c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT,
        c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT,
    );
}

fn renderParticlePass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info, batches: std.EnumArray(Shader.Kind, ParticleBatch)) void {
    var color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);

    const particle_pipeline_layout_handle = self.resources.pipeline_layouts.get(.particle).handle;
    self.bindWorldDescriptors(cmd, current_frame, particle_pipeline_layout_handle);

    for (std.enums.values(Shader.Kind)) |effect| {
        if (Shader.get(effect).particle == null) continue;
        const batch = batches.get(effect);
        if (batch.emitter_count == 0) continue;

        bindVertexShader(cmd, self.resources.shader_loader.shaderPtr(effect, .vert));
        bindFragmentShader(cmd, self.resources.shader_loader.shaderPtr(effect, .frag));

        const push = particlePushConstant(self, current_frame, info, effect, batch);
        c.vkCmdPushConstants(cmd, particle_pipeline_layout_handle, Shader.pushConstantStages(.particle), 0, @sizeOf(Shader.ParticlePushConstant), &push);
        c.vkCmdDraw(cmd, 6, batch.emitter_count * push.particle_count, 0, 0);
    }

    color_blend_enables = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    self.bindWorldDescriptors(cmd, current_frame, self.resources.pipeline_layouts.get(.world).handle);
}

fn renderDebugPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) !void {
    if (!info.world.controller.debug_draw_colliders) return;

    const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
    const handles = [_]c.VkShaderEXT{ self.resources.shader_loader.shaderPtr(.debug_vert, .vert).handle, self.resources.shader_loader.shaderPtr(.debug_frag, .frag).handle };
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

fn renderUiPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, ui: *const Ui, width: f32, height: f32) void {
    current_frame.ui_vertex_buffer.copy(Ui.Quad, ui.quads.items);
    const stages_ui = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const bounds_ui = [_]c.VkShaderEXT{
        self.resources.shader_loader.shaderPtr(.ui_vert, .vert).handle,
        self.resources.shader_loader.shaderPtr(.ui_frag, .frag).handle,
    };

    ext.vkCmdBindShadersEXT(cmd, 2, &stages_ui[0], &bounds_ui[0]);

    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_FALSE);
    const color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);
    const ui_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.texture_table.descriptor_buffer.getGPUAddress(),
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
    c.vkCmdBindIndexBuffer(cmd, self.resources.ui_index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(cmd, @as(u32, @intCast(ui.quads.items.len * 6)), 1, 0, 0, 0);
}

fn fileEntry(self: *Vulkan, model_handle: Model.Handle) ?*ModelLoader.Entry {
    return switch (model_handle) {
        .file => |file_index| &self.resources.model_loader.entries[file_index],
        .generated => null,
    };
}

fn drawStatic(self: *Vulkan, cmd: c.VkCommandBuffer, model_handle: Model.Handle, top_matrix: nz.Mat4x4(f32)) !void {
    switch (model_handle) {
        .generated => |generated_kind| {
            const generated_slot = self.resources.generated.getPtr(generated_kind);
            if (generated_slot.*) |*mesh| {
                var push: Shader.WorldPushConstant = .{
                    .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
                    .model_matrix = top_matrix.d,
                    .joint_matrices_address = 0,
                    .texture_index = 0,
                };
                try emitNode(self, cmd, mesh, &push);
            }
        },
        .file => |file_index| {
            const entry = &self.resources.model_loader.entries[file_index];
            if (entry.model.isEmpty() or entry.model.isSkinned()) return;
            for (entry.model.surfaces.items) |surface| {
                const mesh = &entry.meshes[surface.mesh_id];
                const surface_matrix = top_matrix.mul(surface.model_matrix);
                var push: Shader.WorldPushConstant = .{
                    .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
                    .model_matrix = surface_matrix.d,
                    .joint_matrices_address = 0,
                    .texture_index = 0,
                };
                try emitNode(self, cmd, mesh, &push);
            }
        },
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

fn drawSkinned(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    skeleton: *const AnimationInstance.Skeleton,
    meshes: []Mesh,
    joint_buffers: []Buffer,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (skeleton.nodes) |node| {
        const mesh_id = node.mesh_id orelse continue;
        const mesh = &meshes[mesh_id];
        var push: Shader.WorldPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = if (node.skin_id != null) top_matrix.d else top_matrix.mul(node.model_matrix).d,
            .joint_matrices_address = if (node.skin_id) |skin_index|
                joint_buffers[skin_index].getGPUAddress()
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

fn bindWorldDescriptors(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, world_pipeline_layout_handle: c.VkPipelineLayout) void {
    const shadow_descriptor_buffer = &self.resources.shadow_descriptor_buffers[self.current_frame_inflight % self.frames.len];
    const world_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = current_frame.gpu_scene.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.texture_table.descriptor_buffer.getGPUAddress(),
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
}

pub fn drainRenderCommands(self: *Vulkan, gpa: std.mem.Allocator, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), world: *World) !void {
    self.planet.drainRetired(gpa, self.vma, self.current_frame_inflight);
    try self.planet.collect(gpa, self.vma, self.device, world, self.current_frame_inflight);
    if (self.resources.model_loader.reloaded.items.len != 0) {
        for (self.resources.model_loader.reloaded.items) |file_index| {
            const loader_entry = &self.resources.model_loader.entries[file_index];
            var instance_iterator = instances.iterator();
            while (instance_iterator.next()) |entry| {
                const instance = entry.value_ptr;
                if (instance.model != &loader_entry.model) continue;
                if (instance.skeleton) |*skeleton| skeleton.deinit(gpa);
                instance.skeleton = if (loader_entry.model.isSkinned()) try .init(gpa, &loader_entry.model) else null;
                if (self.joint_buffers.getPtr(entry.key_ptr.*)) |joint_buffers| {
                    for (joint_buffers.*) |*joint_buffer| joint_buffer.deinit(self.vma);
                    gpa.free(joint_buffers.*);
                    joint_buffers.* = try self.createJointBuffers(gpa, &loader_entry.model);
                }
            }
        }
        self.resources.model_loader.reloaded.clearRetainingCapacity();
    }
    for (world.render_outbox.items) |command| switch (command) {
        .entity_spawned => |spawned| {
            if (spawned.kind == .planet) {
                try self.planet.build(gpa, spawned.id, @intFromFloat(world.planet_radius), self.current_frame_inflight);
                continue;
            }
            const entity = world.getPtr(spawned.id) orelse continue;
            const path = shared.entity.modelSpec(spawned.kind).path;
            entity.model_handle = if (std.mem.endsWith(u8, path, ".glb"))
                .{ .file = self.resources.model_loader.indices_by_path.get(path) orelse std.debug.panic("no glb on disk for {s}", .{path}) }
            else
                .{ .generated = std.meta.stringToEnum(Model.Generated, path).? };
            try self.ensureInstance(gpa, instances, entity, entity.model_handle);
        },
        .entity_despawned => |id| {
            if (instances.fetchRemove(id)) |removed| {
                var instance = removed.value;
                instance.deinit(gpa);
            }
            self.removeSkeleton(gpa, id);
            try self.planet.remove(gpa, id, self.current_frame_inflight);
        },
    };
    world.render_outbox.clearRetainingCapacity();
    try self.planet.update(gpa, world);
}

fn createJointBuffers(self: *Vulkan, gpa: std.mem.Allocator, model: *const Model) ![]Buffer {
    const joint_buffers = try gpa.alloc(Buffer, model.skins.len);
    for (model.skins, joint_buffers) |skin, *joint_buffer| {
        joint_buffer.* = try .init(
            self.device,
            self.vma,
            nz.Mat4x4(f32),
            skin.inverse_bind_matrices.?.len,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        );
    }
    return joint_buffers;
}

fn ensureInstance(self: *Vulkan, gpa: std.mem.Allocator, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), entity: *system.Entity, model_handle: Model.Handle) !void {
    if (instances.contains(entity.id)) return;
    const entry = fileEntry(self, model_handle) orelse {
        try instances.put(entity.id, try .init(gpa, null));
        return;
    };
    if (entry.model.isEmpty() and entity.kind.expectsModel()) {
        std.debug.panic("no model registered for {s}", .{@tagName(entity.kind)});
    }
    try instances.put(entity.id, try .init(gpa, &entry.model));
    if (entry.model.isSkinned() and !self.joint_buffers.contains(entity.id)) {
        try self.joint_buffers.put(entity.id, try self.createJointBuffers(gpa, &entry.model));
    }
}

fn removeSkeleton(self: *Vulkan, gpa: std.mem.Allocator, entity_id: shared.entity.Id) void {
    if (self.joint_buffers.fetchRemove(entity_id)) |kv| {
        for (kv.value) |*joint_buffer| {
            var joint_buffer_copy = joint_buffer.*;
            joint_buffer_copy.deinit(self.vma);
        }
        gpa.free(kv.value);
    }
}

fn clearSkeletons(self: *Vulkan, gpa: std.mem.Allocator) void {
    var it = self.joint_buffers.valueIterator();
    while (it.next()) |joint_buffers| {
        for (joint_buffers.*) |*joint_buffer| joint_buffer.deinit(self.vma);
        gpa.free(joint_buffers.*);
    }
    self.joint_buffers.clearRetainingCapacity();
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
