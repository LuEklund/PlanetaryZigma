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
const Ui = @import("../Ui.zig");
const procs = @import("Vulkan/procs.zig");
const ext = procs.device.ProcTable;
const tracy = @import("ztracy");

const matrix = @import("Vulkan/matrix.zig");
const debug = @import("Vulkan/debug.zig");

const check = @import("Vulkan/utils.zig").check;

pub const Model = @import("../asset/Model.zig");
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

pub fn rebindProcs(self: *Vulkan) void {
    procs.instance.load(self.instance.handle, null);
    procs.device.load(self.device.handle, null);
}

const frame_timeout_ns: u64 = 1000000000;

pub fn update(self: *Vulkan, world: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), ui: *const Ui, draw_sky: bool) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const current_frame = &self.frames[self.current_frame_inflight % self.frames.len];
    const cmd_buffer = current_frame.command_buffer;

    try check(c.vkWaitForFences(self.device.handle, 1, &current_frame.render_fence, 1, frame_timeout_ns));
    const image_index = acquireNextImage(self, current_frame) orelse return;
    try check(c.vkResetFences(self.device.handle, 1, &current_frame.render_fence));
    const render_semaphore: c.VkSemaphore = self.swapchain.render_semaphores[image_index];

    try beginCommandBuffer(cmd_buffer);
    try render(self, cmd_buffer, current_frame, world, instances, ui, draw_sky);
    blitOntoSwapchain(self, cmd_buffer, image_index);
    try check(c.vkEndCommandBuffer(cmd_buffer));

    try submitFrame(self, cmd_buffer, current_frame, render_semaphore);

    const present_result = presentFrame(self, render_semaphore, image_index);
    if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR) {
        return;
    }
    self.current_frame_inflight += 1;
}

fn acquireNextImage(self: *Vulkan, current_frame: *const FrameData) ?u32 {
    var image_index: u32 = undefined;
    const acquire_result = c.vkAcquireNextImageKHR(
        self.device.handle,
        self.swapchain.swapchain,
        frame_timeout_ns,
        current_frame.swapchain_semaphore,
        null,
        &image_index,
    );
    return switch (acquire_result) {
        c.VK_ERROR_OUT_OF_DATE_KHR, c.VK_TIMEOUT, c.VK_NOT_READY => null,
        else => image_index,
    };
}

fn beginCommandBuffer(cmd: c.VkCommandBuffer) !void {
    try check(c.vkResetCommandBuffer(cmd, 0));
    const cmd_begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(c.vkBeginCommandBuffer(cmd, &cmd_begin_info));
}

fn blitOntoSwapchain(self: *Vulkan, cmd: c.VkCommandBuffer, image_index: u32) void {
    var swapchain_image_barrier: Image.Barrier = .init(cmd, self.swapchain.images[image_index], c.VK_IMAGE_ASPECT_COLOR_BIT);
    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT);
    self.swapchain.draw_image.copyOntoImage(
        cmd,
        .{ .vk_image = self.swapchain.images[image_index], .extent = self.swapchain.extent },
    );
    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
}

fn submitFrame(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, render_semaphore: c.VkSemaphore) !void {
    const submit_info: c.VkSubmitInfo2 = .{
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
            .commandBuffer = cmd,
        },
    };
    try check(c.vkQueueSubmit2(self.device.graphics_queue, 1, &submit_info, current_frame.render_fence));
}

fn presentFrame(self: *Vulkan, render_semaphore: c.VkSemaphore, image_index: u32) c.VkResult {
    const present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pSwapchains = &self.swapchain.swapchain,
        .swapchainCount = 1,
        .pWaitSemaphores = &render_semaphore,
        .waitSemaphoreCount = 1,
        .pImageIndices = &image_index,
    };
    return c.vkQueuePresentKHR(self.device.graphics_queue, &present_info);
}

pub fn render(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, world: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), ui: *const Ui, draw_sky: bool) !void {
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
    setDefaultRenderState(self, cmd);

    uploadSceneData(self, current_frame, world);
    const cascade_vps = uploadCascades(self, world);
    uploadJointMatrices(self, instances);

    renderShadowPass(self, cmd, world, instances, cascade_vps);

    const particle_batches = packEmitters(current_frame, world);

    beginRendering(self, cmd);
    renderWorldPass(self, cmd, current_frame, world, instances);
    if (draw_sky) renderSkyPass(self, cmd, current_frame);
    renderParticlePass(self, cmd, current_frame, world, particle_batches);
    if (world.controller.debug_draw_colliders) renderDebugPass(self, cmd, current_frame, world);
    renderUiPass(self, cmd, current_frame, ui);
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

        const bound = [_]c.VkShaderEXT{ self.resources.shader_loader.vert(.skinned).handle, self.resources.shader_loader.frag(.mesh).handle, null, null, null };
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

fn uploadSceneData(self: *Vulkan, current_frame: *FrameData, world: *World) void {
    const camera_transform = world.camera.transform;
    const view_matrix = matrix.getViewMatrix(&camera_transform);
    var proj = matrix.perspective(world.camera.fov_rad, drawAspect(self), 0.01, 1000);
    const proj_view = proj.mul(view_matrix);

    var scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_proj_rotation = camera_transform.rotation.toMat4x4().mul(proj.inverse()).d,
        .global_light_direction = lightDirection(world.elapsed_time),
        .time = world.elapsed_time,
        .camera_position = camera_transform.position,
        .light_color = if (world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{
            1, 0.5, 0.5, 1,
        },
        .camera_up = up: {
            const up = camera_transform.rotation.rotateVec(.{ 0, 1, 0 });
            break :up .{ up[0], up[1], up[2], 0 };
        },
    };
    current_frame.gpu_scene.copy(FrameData.GPUScene, (&scene_data)[0..1]);
}

fn uploadCascades(self: *Vulkan, world: *World) [Resources.shadow_cascade_count]nz.Mat4x4(f32) {
    const camera_transform = world.camera.transform;
    const fov_rad: f32 = world.camera.fov_rad;
    const aspect: f32 = drawAspect(self);
    const light_dir = lightDirection(world.elapsed_time);

    var cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32) = undefined;
    var cascades: Resources.GPUCascades = undefined;
    cascades.splits = .{ shadow_splits[0], shadow_splits[1], shadow_splits[2], 0 };
    for (0..Resources.shadow_cascade_count) |cascade_index| {
        const slice_near: f32 = if (cascade_index == 0) 0.05 else shadow_splits[cascade_index - 1];
        cascade_vps[cascade_index] = matrix.cascadeViewProj(camera_transform, fov_rad, aspect, slice_near, shadow_splits[cascade_index], light_dir);
        cascades.light_view_proj[cascade_index] = cascade_vps[cascade_index].d;
    }
    self.resources.writeCascades(self.current_frame_inflight % self.frames.len, &cascades);
    return cascade_vps;
}

fn uploadJointMatrices(self: *Vulkan, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) void {
    var joint_upload_iterator = self.joint_buffers.iterator();
    while (joint_upload_iterator.next()) |entry| {
        const instance = instances.getPtr(entry.key_ptr.*) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        for (skeleton.joint_matrices, entry.value_ptr.*) |cpu_matrices, *joint_buffer| {
            joint_buffer.copy(nz.Mat4x4(f32), cpu_matrices);
        }
    }
}

fn drawAspect(self: *const Vulkan) f32 {
    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    return width / height;
}

fn lightDirection(elapsed_time: f32) nz.Vec3(f32) {
    const light_time = elapsed_time * 0.01 + 0.9;
    return nz.vec.normalize(@as(nz.Vec3(f32), .{ @cos(light_time), @sin(light_time), 0.3 }));
}

fn beginRendering(self: *Vulkan, cmd: c.VkCommandBuffer) void {
    const color_attachment: c.VkRenderingAttachmentInfo = .{
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
                // .float32 = .{ (@sin(world.elapsed_time) + 1) / 2, (@cos(world.elapsed_time) + 1) / 2, (@tan(world.elapsed_time) + 1) / 2, 1.0 },
                .float32 = .{ 0, 0, 0, 1 },
            },
        },
    };
    const depth_attachment: c.VkRenderingAttachmentInfo = .{
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
    const render_info: c.VkRenderingInfo = .{
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
    ext.vkCmdBeginRendering(cmd, &render_info);
}

fn renderShadowPass(self: *Vulkan, cmd: c.VkCommandBuffer, world: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32)) void {
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
        const handles = [_]c.VkShaderEXT{ self.resources.shader_loader.vert(.shadow_static).handle, null };
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

        bindVertexShader(cmd, self.resources.shader_loader.vert(.shadow_static));
        for (world.entities.values()) |*entity| {
            const model_handle = entity.model_handle orelse continue;
            const model_spec = shared.entity.modelSpec(entity.kind) orelse continue;
            if (!matrix.cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const offset = model_spec.offset;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(offset.toMat4x4()));
            drawStatic(self, cmd, model_handle, base_matrix);
        }
        bindVertexShader(cmd, self.resources.shader_loader.vert(.shadow_skinned));
        for (world.entities.values()) |*entity| {
            const instance = instances.getPtr(entity.id) orelse continue;
            const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
            const model_handle = entity.model_handle orelse continue;
            const model_spec = shared.entity.modelSpec(entity.kind) orelse continue;
            const entry = fileEntry(self, model_handle) orelse continue;
            const joint_buffers = self.joint_buffers.getPtr(entity.id) orelse continue;
            if (!matrix.cascadeContains(&cascade_vp, entity.transform.position)) continue;
            const offset = model_spec.offset;
            const base_matrix = cascade_vp.mul(entity.transform.toMat4x4().mul(offset.toMat4x4()));
            drawSkinned(self, cmd, skeleton, entry.meshes, joint_buffers.*, base_matrix);
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

fn renderWorldPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, world: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) void {
    const color_blend_enables: c.VkBool32 = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_BACK_BIT);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_TRUE);

    self.bindWorldDescriptors(cmd, current_frame, self.resources.pipeline_layouts.get(.world).handle);

    bindVertexShader(cmd, self.resources.shader_loader.vert(.static));
    bindFragmentShader(cmd, self.resources.shader_loader.frag(.mesh));
    for (world.entities.values()) |*entity| {
        const model_handle = entity.model_handle orelse continue;
        const model_spec = shared.entity.modelSpec(entity.kind) orelse continue;
        const offset = model_spec.offset;
        const base_matrix = entity.transform.toMat4x4().mul(offset.toMat4x4());
        drawStatic(self, cmd, model_handle, base_matrix);
    }

    if (world.getPtr(self.planet.planet_id)) |planet| {
        const transform = planet.transform.toMat4x4();
        for (self.planet.meshes.values()) |*maybe_mesh| if (maybe_mesh.*) |*mesh| try drawPlanetChunk(self, cmd, mesh, transform);
    }

    bindVertexShader(cmd, self.resources.shader_loader.vert(.skinned));
    for (world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        const model_handle = entity.model_handle orelse continue;
        const model_spec = shared.entity.modelSpec(entity.kind) orelse continue;
        const entry = fileEntry(self, model_handle) orelse continue;
        const joint_buffers = self.joint_buffers.getPtr(entity.id) orelse continue;
        const offset = model_spec.offset;
        const base_matrix = entity.transform.toMat4x4().mul(offset.toMat4x4());
        drawSkinned(self, cmd, skeleton, entry.meshes, joint_buffers.*, base_matrix);
    }
}

fn renderSkyPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData) void {
    const color_blend_enables: c.VkBool32 = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    {
        const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const handle = [_]c.VkShaderEXT{ self.resources.shader_loader.vert(.sky).handle, self.resources.shader_loader.frag(.sky).handle };
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
}

const ParticleBatch = struct { first_emitter: u32, emitter_count: u32 };

fn packEmitters(current_frame: *const FrameData, world: *World) std.EnumArray(Shader.Kind, ParticleBatch) {
    const gpu_emitters: [*]FrameData.GPUEmitter = @ptrCast(@alignCast(current_frame.emitter_buffer.info.pMappedData));
    var batches: std.EnumArray(Shader.Kind, ParticleBatch) = .initFill(.{ .first_emitter = 0, .emitter_count = 0 });
    var first_emitter: u32 = 0;
    for (std.enums.values(Shader.Kind)) |effect| {
        if (Shader.get(effect).particle == null) continue;
        var emitter_count: u32 = 0;
        for (&world.emitters) |emitter| {
            if (emitter.effect != effect) continue;
            if (!emitter.alive(world.elapsed_time)) continue;
            gpu_emitters[first_emitter + emitter_count] = .{
                .origin = emitter.origin,
                .spawn_time = emitter.spawn_time,
                .target = emitter.target,
            };
            emitter_count += 1;
        }
        batches.set(effect, .{ .first_emitter = first_emitter, .emitter_count = emitter_count });
        first_emitter += emitter_count;
    }
    return batches;
}

fn renderParticlePass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, world: *World, batches: std.EnumArray(Shader.Kind, ParticleBatch)) void {
    const color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);

    const particle_pipeline_layout_handle = self.resources.pipeline_layouts.get(.particle).handle;
    self.bindWorldDescriptors(cmd, current_frame, particle_pipeline_layout_handle);

    for (std.enums.values(Shader.Kind)) |effect| {
        if (Shader.get(effect).particle == null) continue;
        const batch = batches.get(effect);
        if (batch.emitter_count == 0) continue;

        bindVertexShader(cmd, self.resources.shader_loader.vert(effect));
        bindFragmentShader(cmd, self.resources.shader_loader.frag(effect));

        const push: Shader.ParticlePushConstant = .{
            .emitter_buffer_address = current_frame.emitter_buffer.getGPUAddress() +
                batch.first_emitter * @sizeOf(FrameData.GPUEmitter),
            .elapsed_time = world.elapsed_time,
            .particle_count = Shader.particleInfo(effect).particle_count,
            .emitter_count = batch.emitter_count,
            .duration = Shader.particleInfo(effect).duration orelse 0,
        };
        c.vkCmdPushConstants(cmd, particle_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.ParticlePushConstant), &push);
        c.vkCmdDraw(cmd, 6, batch.emitter_count * Shader.instancesPerEmitter(effect), 0, 0);
    }
}

fn renderDebugPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, world: *World) void {
    const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
    const handles = [_]c.VkShaderEXT{ self.resources.shader_loader.vert(.debug).handle, self.resources.shader_loader.frag(.debug).handle };
    ext.vkCmdBindShadersEXT(cmd, 2, &stages[0], &handles[0]);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST);
    c.vkCmdSetLineWidth(cmd, 1);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    const color_blend_enables: c.VkBool32 = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);

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
    for (world.entities.values()) |*entity| {
        const collider_shape = (shared.entity.collider(entity.kind) orelse continue).shape;
        const first_vertex = debug_vertex_count;
        switch (collider_shape) {
            .capsule => |capsule| debug.appendCapsuleLines(debug_vertices, &debug_vertex_count, capsule.half_heigth, capsule.radius),
            .box => |box| debug.appendBoxLines(
                debug_vertices,
                &debug_vertex_count,
                box,
            ),
        }
        var collider_transform = entity.transform;
        collider_transform.scale = @splat(1);
        var push: Shader.WorldPushConstant = .{
            .vertex_buffer_address = current_frame.debug_vertex_buffer.getGPUAddress() +
                first_vertex * @sizeOf(FrameData.DebugVertex),
            .model_matrix = collider_transform.toMat4x4().d,
            .joint_matrices_address = 0,
            .texture_index = 0,
        };
        c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.WorldPushConstant), &push);
        c.vkCmdDraw(cmd, debug_vertex_count - first_vertex, 1, 0, 0);
    }
}

fn renderUiPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *FrameData, ui: *const Ui) void {
    current_frame.ui_vertex_buffer.copy(Ui.Quad, ui.quads.items);
    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    const stages_ui = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const bounds_ui = [_]c.VkShaderEXT{
        self.resources.shader_loader.vert(.ui).handle,
        self.resources.shader_loader.frag(.ui).handle,
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
        .screnn_size = .{ ui.screen_width, ui.screen_heigth },
    };
    c.vkCmdPushConstants(cmd, ui_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.UiPushConstant), &push);
    c.vkCmdBindIndexBuffer(cmd, self.resources.ui_index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(cmd, @as(u32, @intCast(ui.quads.items.len * 6)), 1, 0, 0, 0);
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

fn drawStatic(self: *Vulkan, cmd: c.VkCommandBuffer, model_handle: Model.Handle, top_matrix: nz.Mat4x4(f32)) void {
    switch (model_handle) {
        .generated => |generated_kind| {
            const mesh = self.resources.generated.getPtr(generated_kind);
            var push: Shader.WorldPushConstant = .{
                .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
                .model_matrix = top_matrix.d,
                .joint_matrices_address = 0,
                .texture_index = 0,
            };
            emitNode(self, cmd, mesh, &push);
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
                emitNode(self, cmd, mesh, &push);
            }
        },
    }
}

fn drawSkinned(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    skeleton: *const AnimationInstance.Skeleton,
    meshes: []Mesh,
    joint_buffers: []Buffer,
    top_matrix: nz.Mat4x4(f32),
) void {
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
        emitNode(self, cmd, mesh, &push);
    }
}

fn drawPlanetChunk(self: *Vulkan, cmd: c.VkCommandBuffer, mesh: *const Mesh, transform: nz.Mat4x4(f32)) !void {
    var push: Shader.WorldPushConstant = .{
        .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
        .model_matrix = transform.d,
        .joint_matrices_address = 0,
        .texture_index = 0,
    };
    emitNode(self, cmd, mesh, &push);
}

fn emitNode(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    mesh: *const Mesh,
    push: *Shader.WorldPushConstant,
) void {
    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
    c.vkCmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    for (mesh.surfaces.items) |surface| {
        push.texture_index = @intFromEnum(surface.texture);
        c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Shader.WorldPushConstant), push);
        c.vkCmdDrawIndexed(cmd, @intCast(surface.index_count), 1, surface.index_start, 0, 0);
    }
}

fn fileEntry(self: *Vulkan, model_handle: Model.Handle) ?*ModelLoader.Entry {
    return switch (model_handle) {
        .file => |file_index| &self.resources.model_loader.entries[file_index],
        .generated => null,
    };
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
            const path = (shared.entity.modelSpec(spawned.kind) orelse continue).path;
            const model_handle: Model.Handle = if (std.mem.endsWith(u8, path, ".glb"))
                .{ .file = self.resources.model_loader.indices_by_path.get(path).? }
            else
                .{ .generated = std.meta.stringToEnum(Model.Generated, path).? };
            entity.model_handle = model_handle;
            try self.ensureInstance(gpa, instances, entity, model_handle);
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
    if (entry.model.isEmpty()) {
        std.log.err("model not loaded for {s}", .{@tagName(entity.kind)});
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
