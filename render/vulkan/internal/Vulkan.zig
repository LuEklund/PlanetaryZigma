const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const nz = @import("numz");
const vk = @import("vulkan");
const Window = @import("Window");
const Instance = @import("Vulkan/Instance.zig");
const DebugMessenger = @import("Vulkan/DebugMessenger.zig");
const PhysicalDevice = @import("Vulkan/device.zig").Physical;
const Device = @import("Vulkan/device.zig").Logical;
const GpuMemory = @import("Vulkan/GpuMemory.zig");
const Mesh = @import("Vulkan/Mesh.zig");
const Swapchain = @import("Vulkan/Swapchain.zig");
const FrameData = @import("Vulkan/FrameData.zig");
const Surface = @import("Vulkan/Surface.zig");
const Image = @import("Vulkan/Image.zig");
const Resources = @import("Vulkan/Resources.zig");
const PipelineLayout = @import("Vulkan/PipelineLayout.zig");
const Shader = @import("renderer_contract").Shader;
const Shaders = @import("Vulkan/Shaders.zig");
const tracy = @import("ztracy");
const matrix = @import("Vulkan/matrix.zig");
const contract = @import("renderer_contract");
const DrawList = contract.DrawList;

const shadow_splits = [Resources.shadow_cascade_count]f32{ 16, 48, 120 };
const frame_timeout_ns: u64 = 1_000_000_000;

gpa: std.mem.Allocator,
instance: Instance,
debug_messenger: ?DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
heaps: GpuMemory.Heaps,
swapchain: Swapchain,
resources: *Resources,
highlight_mask: contract.TextureHandle,
current_frame_inflight: u32,
swapchain_stale: bool,
frames: [FrameData.max_frames_inflight]FrameData,
sorted_draws: std.ArrayList(u32),

pub fn init(data: *const contract.InitOptions) !*Vulkan {
    const gpa = data.gpa;
    const window: *Window = @ptrCast(@alignCast(data.window));
    const self = try gpa.create(Vulkan);
    self.gpa = gpa;
    self.current_frame_inflight = 0;
    self.swapchain_stale = false;

    self.instance = try .init(gpa, Surface.instanceExtensions(window));
    const renderdoc = try std.process.Environ.contains(.empty, gpa, "RENDERDOC_CAPFILE");
    self.debug_messenger = if (builtin.mode == .Debug and !renderdoc) try .init(self.instance, .{
        .severities = .{ .verbose_bit_ext = true, .info_bit_ext = true, .warning_bit_ext = true, .error_bit_ext = true },
    }) else null;
    self.surface = try .create(self.instance, window);
    self.physical_device = try .pick(gpa, self.instance, self.surface.handle);
    self.device = try .init(gpa, self.instance, self.physical_device);
    self.heaps = try .init(self.device, self.physical_device.memory_properties);
    self.swapchain = try .init(gpa, &self.heaps.device, self.instance, self.physical_device, self.device, self.surface, window.size.width, window.size.height);
    for (&self.frames) |*frame| frame.* = try .init(&self.heaps.host, self.device);

    self.resources = try .init(gpa, &self.heaps, self.device);
    for (self.frames, 0..) |frame, frame_index| self.resources.writeSceneSet(frame_index, frame.gpu_scene);
    self.highlight_mask = self.resources.texture_table.alloc();
    self.resources.writeTexture(self.highlight_mask, self.swapchain.mask_image.vk_imageview);

    self.sorted_draws = try .initCapacity(gpa, DrawList.max_draw_meshes);
    return self;
}

pub fn deinit(self: *Vulkan, gpa: std.mem.Allocator) void {
    self.device.proxy.deviceWaitIdle() catch {};
    self.sorted_draws.deinit(gpa);
    self.resources.deinit(&self.heaps);
    for (&self.frames) |*frame| frame.deinit(&self.heaps.host, self.device);
    self.swapchain.deinit(&self.heaps.device, self.device);
    self.heaps.deinit(self.device);
    self.device.deinit(gpa);
    self.surface.deinit(self.instance);
    if (self.debug_messenger) |debug_messenger| debug_messenger.deinit(self.instance);
    self.instance.deinit(gpa);
    gpa.destroy(self);
}

pub fn resize(self: *Vulkan, width: u32, height: u32) !void {
    try self.swapchain.recreate(self.gpa, &self.heaps.device, self.instance, self.physical_device, self.device, self.surface, width, height);
    self.resources.writeTexture(self.highlight_mask, self.swapchain.mask_image.vk_imageview);
}

pub fn update(self: *Vulkan, list: *const DrawList) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.resources.drainRetired(&self.heaps, self.current_frame_inflight);
    if (self.swapchain_stale or list.surface_width != self.swapchain.extent.width or list.surface_height != self.swapchain.extent.height) {
        try self.resize(list.surface_width, list.surface_height);
        self.swapchain_stale = false;
    }

    const current_frame = &self.frames[self.frameIndex()];
    const cmd = current_frame.command_buffer;

    if (try self.device.proxy.waitForFences(&.{current_frame.render_fence}, .true, frame_timeout_ns) == .timeout) {
        std.log.warn("render: frame fence timed out, skipping frame", .{});
        return;
    }
    const image_index = self.acquireNextImage(current_frame) orelse return;
    const render_semaphore = self.swapchain.render_semaphores[image_index];

    try self.device.proxy.resetCommandBuffer(cmd, .{});
    try self.device.proxy.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    self.render(cmd, current_frame, list);
    self.blitOntoSwapchain(cmd, image_index);
    try self.device.proxy.endCommandBuffer(cmd);

    try self.submitFrame(cmd, current_frame, render_semaphore);

    const present_result = self.device.proxy.queuePresentKHR(self.device.graphics_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&render_semaphore),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain.swapchain),
        .p_image_indices = @ptrCast(&image_index),
    }) catch |err| switch (err) {
        error.OutOfDateKHR => {
            self.swapchain_stale = true;
            return;
        },
        else => return err,
    };
    if (present_result == .suboptimal_khr) {
        self.swapchain_stale = true;
        return;
    }
    self.current_frame_inflight += 1;
}

fn acquireNextImage(self: *Vulkan, current_frame: *const FrameData) ?u32 {
    const acquired = self.device.proxy.acquireNextImageKHR(self.swapchain.swapchain, frame_timeout_ns, current_frame.swapchain_semaphore, .null_handle) catch |err| {
        if (err == error.OutOfDateKHR) self.swapchain_stale = true;
        return null;
    };
    return switch (acquired.result) {
        .timeout, .not_ready => null,
        else => acquired.image_index,
    };
}

fn blitOntoSwapchain(self: *Vulkan, cmd: vk.CommandBuffer, image_index: u32) void {
    var swapchain_image_barrier: Image.Barrier = .init(self.device, cmd, self.swapchain.images[image_index], .{ .color_bit = true });
    swapchain_image_barrier.transition(.transfer_dst_optimal, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true });
    self.swapchain.draw_image.copyOntoImage(self.device, cmd, self.swapchain.images[image_index], self.swapchain.extent);
    swapchain_image_barrier.transition(.present_src_khr, .{ .bottom_of_pipe_bit = true }, .{});
}

fn submitFrame(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, render_semaphore: vk.Semaphore) !void {
    const wait = [_]vk.SemaphoreSubmitInfo{.{ .semaphore = current_frame.swapchain_semaphore, .value = 0, .stage_mask = .{ .color_attachment_output_bit = true }, .device_index = 0 }};
    const signal = [_]vk.SemaphoreSubmitInfo{.{ .semaphore = render_semaphore, .value = 0, .stage_mask = .{ .all_graphics_bit = true }, .device_index = 0 }};
    const command_buffers = [_]vk.CommandBufferSubmitInfo{.{ .command_buffer = cmd, .device_mask = 0 }};
    const submit = [_]vk.SubmitInfo2{.{
        .wait_semaphore_info_count = wait.len,
        .p_wait_semaphore_infos = &wait,
        .command_buffer_info_count = command_buffers.len,
        .p_command_buffer_infos = &command_buffers,
        .signal_semaphore_info_count = signal.len,
        .p_signal_semaphore_infos = &signal,
    }};
    try self.device.proxy.resetFences(&.{current_frame.render_fence});
    self.device.proxy.queueSubmit2(self.device.graphics_queue, &submit, current_frame.render_fence) catch |err| {
        self.device.proxy.queueSubmit2(self.device.graphics_queue, null, current_frame.render_fence) catch {};
        return err;
    };
}

fn render(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *FrameData, list: *const DrawList) void {
    var draw_image_barrier: Image.Barrier = .init(self.device, cmd, self.swapchain.draw_image.vk_image, .{ .color_bit = true });
    draw_image_barrier.transition(.color_attachment_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true });

    self.setDefaultRenderState(cmd);
    self.uploadSceneData(current_frame, list);
    const cascade_vps = self.uploadCascades(list);
    current_frame.joint_buffer.copy(nz.Mat4x4(f32), list.joint_matrices.items);

    self.renderShadowPass(cmd, current_frame, list, cascade_vps);
    self.renderHighlightPass(cmd, current_frame, list);
    const particle_batches = packEmitters(current_frame, list);

    self.beginRendering(cmd);
    self.renderWorldPass(cmd, current_frame, list);
    if (list.draw_sky) self.renderSkyPass(cmd);
    self.renderWorldTransparentPass(cmd, current_frame, list);
    self.renderParticlePass(cmd, current_frame, list, particle_batches);
    self.renderOutlinePass(cmd);
    if (list.draw_lines.items.len != 0) self.renderDebugPass(cmd, current_frame, list);
    self.renderDvuiPass(cmd, current_frame, list);
    self.device.proxy.cmdEndRendering(cmd);

    draw_image_barrier.transition(.transfer_src_optimal, .{ .all_transfer_bit = true }, .{ .transfer_read_bit = true });
}

fn fullViewport(self: *const Vulkan) vk.Viewport {
    return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain.draw_image.extent.width),
        .height = @floatFromInt(self.swapchain.draw_image.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
}

fn fullScissor(self: *const Vulkan) vk.Rect2D {
    return .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = self.swapchain.draw_image.extent.width, .height = self.swapchain.draw_image.extent.height },
    };
}

fn setDefaultRenderState(self: *Vulkan, cmd: vk.CommandBuffer) void {
    const proxy = self.device.proxy;
    proxy.cmdSetViewportWithCount(cmd, &.{self.fullViewport()});
    proxy.cmdSetScissorWithCount(cmd, &.{self.fullScissor()});
    proxy.cmdSetCullMode(cmd, .{ .back_bit = true });
    proxy.cmdSetFrontFace(cmd, .counter_clockwise);
    proxy.cmdSetDepthTestEnable(cmd, .true);
    proxy.cmdSetDepthWriteEnable(cmd, .true);
    proxy.cmdSetDepthCompareOp(cmd, .less_or_equal);
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
    proxy.cmdSetDepthBiasEnable(cmd, .false);
    proxy.cmdSetDepthBias(cmd, 0, 0, 0);
    proxy.cmdSetLineWidth(cmd, 1);
}

fn uploadSceneData(self: *Vulkan, current_frame: *FrameData, list: *const DrawList) void {
    const camera_transform: nz.Transform3D(f32) = .{ .position = list.camera.position, .rotation = list.camera.rotation };
    const view_matrix = matrix.getViewMatrix(&camera_transform);
    var proj = matrix.perspective(list.camera.fov_rad, self.drawAspect(), 0.01, 1000);
    const proj_view = proj.mul(view_matrix);
    const up = camera_transform.rotation.rotateVec(.{ 0, 1, 0 });
    const scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_proj_rotation = camera_transform.rotation.toMat4x4().mul(proj.inverse()).d,
        .to_sun = list.sun_direction,
        .time = list.time,
        .planet_radius = list.planet_radius,
        .camera_position = camera_transform.position,
        .light_color = list.light_color,
        .sky_zenith = list.sky_zenith,
        .sky_horizon = list.sky_horizon,
        .camera_up = .{ up[0], up[1], up[2], 0 },
    };
    current_frame.gpu_scene.copy(FrameData.GPUScene, (&scene_data)[0..1]);
}

fn uploadCascades(self: *Vulkan, list: *const DrawList) [Resources.shadow_cascade_count]nz.Mat4x4(f32) {
    const camera_transform: nz.Transform3D(f32) = .{ .position = list.camera.position, .rotation = list.camera.rotation };
    var cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32) = undefined;
    var cascades: Resources.GPUCascades = undefined;
    cascades.splits = .{ shadow_splits[0], shadow_splits[1], shadow_splits[2], 0 };
    for (0..Resources.shadow_cascade_count) |cascade_index| {
        const slice_near: f32 = if (cascade_index == 0) 0.05 else shadow_splits[cascade_index - 1];
        cascade_vps[cascade_index] = matrix.cascadeViewProj(camera_transform, list.camera.fov_rad, self.drawAspect(), slice_near, shadow_splits[cascade_index], list.sun_direction);
        cascades.light_view_proj[cascade_index] = cascade_vps[cascade_index].d;
    }
    self.resources.writeCascades(self.frameIndex(), &cascades);
    return cascade_vps;
}

fn drawAspect(self: *const Vulkan) f32 {
    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    return width / height;
}

fn beginRendering(self: *Vulkan, cmd: vk.CommandBuffer) void {
    const color_attachment = [_]vk.RenderingAttachmentInfo{.{
        .image_view = self.swapchain.draw_image.vk_imageview,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
    }};
    const depth_attachment: vk.RenderingAttachmentInfo = .{
        .image_view = self.swapchain.depth_image.vk_imageview,
        .image_layout = .depth_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };
    self.device.proxy.cmdBeginRendering(cmd, &.{
        .render_area = self.fullScissor(),
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = color_attachment.len,
        .p_color_attachments = &color_attachment,
        .p_depth_attachment = &depth_attachment,
    });
}

fn renderShadowPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList, cascade_vps: [Resources.shadow_cascade_count]nz.Mat4x4(f32)) void {
    const proxy = self.device.proxy;
    var shadow_barrier: Image.Barrier = .init(self.device, cmd, self.resources.shadow_image.vk_image, .{ .depth_bit = true });
    shadow_barrier.src_stage = .{ .fragment_shader_bit = true };
    shadow_barrier.src_access = .{ .shader_read_bit = true };
    shadow_barrier.transition(
        .depth_attachment_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
    );
    const depth_attachment: vk.RenderingAttachmentInfo = .{
        .image_view = self.resources.shadow_image.vk_imageview,
        .image_layout = .depth_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };
    proxy.cmdBeginRendering(cmd, &.{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = Resources.shadow_map_size * Resources.shadow_cascade_count, .height = Resources.shadow_map_size },
        },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 0,
        .p_depth_attachment = &depth_attachment,
    });
    self.bindWorldDescriptors(cmd, self.resources.pipeline_layouts.get(.world).handle);
    proxy.cmdSetDepthBiasEnable(cmd, .true);
    proxy.cmdSetDepthBias(cmd, 0, 0, 3);
    for (cascade_vps, 0..) |cascade_vp, cascade_index| {
        const x: u32 = @intCast(cascade_index * Resources.shadow_map_size);
        proxy.cmdSetViewportWithCount(cmd, &.{.{
            .x = @floatFromInt(x),
            .y = 0,
            .width = @floatFromInt(Resources.shadow_map_size),
            .height = @floatFromInt(Resources.shadow_map_size),
            .min_depth = 0,
            .max_depth = 1,
        }});
        proxy.cmdSetScissorWithCount(cmd, &.{.{
            .offset = .{ .x = @intCast(x), .y = 0 },
            .extent = .{ .width = Resources.shadow_map_size, .height = Resources.shadow_map_size },
        }});

        if (self.bindPipeline(cmd, .shadow_static)) for (list.draw_meshes.items) |row| {
            if (row.skinned or !matrix.cascadeContains(&cascade_vp, row.position)) continue;
            const mesh = self.resources.meshAt(row.mesh) orelse continue;
            self.drawMesh(cmd, current_frame, mesh, mesh.surfaces, null, cascade_vp.mul(row.model_matrix));
        };
        if (self.bindPipeline(cmd, .shadow_skinned)) for (list.draw_meshes.items) |row| {
            if (!row.skinned or !matrix.cascadeContains(&cascade_vp, row.position)) continue;
            const mesh = self.resources.meshAt(row.mesh) orelse continue;
            self.drawMesh(cmd, current_frame, mesh, mesh.surfaces, row.palette_offset, cascade_vp.mul(row.model_matrix));
        };
    }
    proxy.cmdEndRendering(cmd);
    shadow_barrier.transition(.shader_read_only_optimal, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true });
    proxy.cmdSetDepthBiasEnable(cmd, .false);
    proxy.cmdSetViewportWithCount(cmd, &.{self.fullViewport()});
    proxy.cmdSetScissorWithCount(cmd, &.{self.fullScissor()});
}

const Farthest = struct {
    rows: []const DrawList.DrawMesh,
    camera: nz.Vec3(f32),

    fn first(self: @This(), a: u32, b: u32) bool {
        const to_a = self.rows[a].position - self.camera;
        const to_b = self.rows[b].position - self.camera;
        return nz.vec.dot(to_a, to_a) > nz.vec.dot(to_b, to_b);
    }
};

fn renderWorldPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList) void {
    const proxy = self.device.proxy;
    proxy.cmdSetCullMode(cmd, .{ .back_bit = true });
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
    proxy.cmdSetDepthTestEnable(cmd, .true);
    proxy.cmdSetDepthWriteEnable(cmd, .true);
    self.bindWorldDescriptors(cmd, self.resources.pipeline_layouts.get(.world).handle);

    self.sorted_draws.clearRetainingCapacity();
    for (0..list.draw_meshes.items.len) |index| self.sorted_draws.appendAssumeCapacity(@intCast(index));
    std.sort.insertion(u32, self.sorted_draws.items, Farthest{ .rows = list.draw_meshes.items, .camera = list.camera.position }, Farthest.first);

    var near_first = std.mem.reverseIterator(self.sorted_draws.items);
    if (self.bindPipeline(cmd, .opaque_static)) while (near_first.next()) |draw_index| {
        const row = list.draw_meshes.items[draw_index];
        if (row.skinned) continue;
        const mesh = self.resources.meshAt(row.mesh) orelse continue;
        if (mesh.opaque_count == 0) continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces[0..mesh.opaque_count], null, row.model_matrix);
    };
    near_first = std.mem.reverseIterator(self.sorted_draws.items);
    if (self.bindPipeline(cmd, .opaque_skinned)) while (near_first.next()) |draw_index| {
        const row = list.draw_meshes.items[draw_index];
        if (!row.skinned) continue;
        const mesh = self.resources.meshAt(row.mesh) orelse continue;
        if (mesh.opaque_count == 0) continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces[0..mesh.opaque_count], row.palette_offset, row.model_matrix);
    };
}

fn renderWorldTransparentPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList) void {
    const proxy = self.device.proxy;
    proxy.cmdSetCullMode(cmd, .{ .back_bit = true });
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
    proxy.cmdSetDepthTestEnable(cmd, .true);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    self.bindWorldDescriptors(cmd, self.resources.pipeline_layouts.get(.world).handle);

    if (self.bindPipeline(cmd, .transparent_static)) for (self.sorted_draws.items) |draw_index| {
        const row = list.draw_meshes.items[draw_index];
        if (row.skinned) continue;
        const mesh = self.resources.meshAt(row.mesh) orelse continue;
        if (mesh.opaque_count == mesh.surfaces.len) continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces[mesh.opaque_count..], null, row.model_matrix);
    };
    if (self.bindPipeline(cmd, .transparent_skinned)) for (self.sorted_draws.items) |draw_index| {
        const row = list.draw_meshes.items[draw_index];
        if (!row.skinned) continue;
        const mesh = self.resources.meshAt(row.mesh) orelse continue;
        if (mesh.opaque_count == mesh.surfaces.len) continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces[mesh.opaque_count..], row.palette_offset, row.model_matrix);
    };
}

fn renderSkyPass(self: *Vulkan, cmd: vk.CommandBuffer) void {
    const proxy = self.device.proxy;
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
    proxy.cmdSetCullMode(cmd, .{});
    proxy.cmdSetDepthTestEnable(cmd, .true);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    proxy.cmdSetDepthCompareOp(cmd, .less_or_equal);
    if (self.resources.skybox_image == null or !self.bindPipeline(cmd, .sky)) return;
    const sky_sets = [_]vk.DescriptorSet{ self.resources.scene_sets[self.frameIndex()], self.resources.texture_table.skybox_set };
    proxy.cmdBindDescriptorSets(cmd, .graphics, self.resources.pipeline_layouts.get(.sky).handle, 0, &sky_sets, null);
    proxy.cmdDraw(cmd, 3, 1, 0, 0);
}

fn renderHighlightPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList) void {
    const proxy = self.device.proxy;
    var mask_barrier: Image.Barrier = .init(self.device, cmd, self.swapchain.mask_image.vk_image, .{ .color_bit = true });
    mask_barrier.transition(.color_attachment_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true });

    const mask_attachment = [_]vk.RenderingAttachmentInfo{.{
        .image_view = self.swapchain.mask_image.vk_imageview,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    }};
    proxy.cmdBeginRendering(cmd, &.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.swapchain.extent.width, .height = self.swapchain.extent.height } },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = mask_attachment.len,
        .p_color_attachments = &mask_attachment,
    });
    proxy.cmdSetDepthTestEnable(cmd, .false);
    proxy.cmdSetCullMode(cmd, .{});
    proxy.cmdSetViewportWithCount(cmd, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain.extent.width),
        .height = @floatFromInt(self.swapchain.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    proxy.cmdSetScissorWithCount(cmd, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.swapchain.extent.width, .height = self.swapchain.extent.height } }});
    self.bindWorldDescriptors(cmd, self.resources.pipeline_layouts.get(.world).handle);

    if (self.bindPipeline(cmd, .highlight_static)) for (list.draw_meshes.items) |draw_mesh| {
        if (!draw_mesh.highlight or draw_mesh.skinned) continue;
        const mesh = self.resources.meshAt(draw_mesh.mesh) orelse continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces, null, draw_mesh.model_matrix);
    };
    if (self.bindPipeline(cmd, .highlight_skinned)) for (list.draw_meshes.items) |draw_mesh| {
        if (!draw_mesh.highlight or !draw_mesh.skinned) continue;
        const mesh = self.resources.meshAt(draw_mesh.mesh) orelse continue;
        self.drawMesh(cmd, current_frame, mesh, mesh.surfaces, draw_mesh.palette_offset, draw_mesh.model_matrix);
    };
    proxy.cmdEndRendering(cmd);
    mask_barrier.transition(.shader_read_only_optimal, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true });
}

const ParticleBatch = struct { first_emitter: u32, emitter_count: u32 };

fn packEmitters(current_frame: *const FrameData, list: *const DrawList) std.EnumArray(contract.ParticleEffect, ParticleBatch) {
    const gpu_emitters: [*]FrameData.GPUEmitter = @ptrCast(@alignCast(current_frame.emitter_buffer.mapped));
    var batches: std.EnumArray(contract.ParticleEffect, ParticleBatch) = .initFill(.{ .first_emitter = 0, .emitter_count = 0 });
    var first_emitter: u32 = 0;
    for (std.enums.values(contract.ParticleEffect)) |effect| {
        var emitter_count: u32 = 0;
        for (list.emitters.items) |emitter| {
            if (emitter.effect != effect) continue;
            gpu_emitters[first_emitter + emitter_count] = .{ .origin = emitter.origin, .spawn_time = emitter.spawn_time, .target = emitter.target };
            emitter_count += 1;
        }
        batches.set(effect, .{ .first_emitter = first_emitter, .emitter_count = emitter_count });
        first_emitter += emitter_count;
    }
    return batches;
}

fn renderOutlinePass(self: *Vulkan, cmd: vk.CommandBuffer) void {
    const proxy = self.device.proxy;
    proxy.cmdSetDepthTestEnable(cmd, .false);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    proxy.cmdSetCullMode(cmd, .{});
    const layout = self.resources.pipeline_layouts.get(.world).handle;
    self.bindWorldDescriptors(cmd, layout);
    if (!self.bindPipeline(cmd, .outline)) return;
    const push: Shader.WorldPushConstant = .{
        .vertex_buffer_address = 0,
        .model_matrix = nz.Mat4x4(f32).identity.d,
        .joint_matrices_address = 0,
        .texture_index = @intFromEnum(self.highlight_mask),
    };
    proxy.cmdPushConstants(cmd, layout, PipelineLayout.push_stages, 0, @sizeOf(Shader.WorldPushConstant), &push);
    proxy.cmdDraw(cmd, 3, 1, 0, 0);
}

fn renderParticlePass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList, batches: std.EnumArray(contract.ParticleEffect, ParticleBatch)) void {
    const proxy = self.device.proxy;
    proxy.cmdSetCullMode(cmd, .{});
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
    proxy.cmdSetDepthTestEnable(cmd, .true);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    const layout = self.resources.pipeline_layouts.get(.particle).handle;
    self.bindWorldDescriptors(cmd, layout);

    for (std.enums.values(contract.ParticleEffect)) |effect| {
        const batch = batches.get(effect);
        if (batch.emitter_count == 0) continue;
        const effect_data = contract.effects.get(effect);
        if (effect_data.count == 0) continue;
        const pipeline: Shaders.Pipeline = switch (effect_data.blend) {
            .alpha => .particles_alpha,
            .additive => .particles_additive,
        };
        if (!self.bindPipeline(cmd, pipeline)) continue;
        const push: Shader.ParticlePushConstant = .{
            .emitter_buffer_address = current_frame.emitter_buffer.getGPUAddress() + batch.first_emitter * @sizeOf(FrameData.GPUEmitter),
            .effect_params_address = self.resources.effect_params_buffer.getGPUAddress() + @intFromEnum(effect) * @sizeOf(contract.Effect.GPU),
            .elapsed_time = list.time,
            .emitter_count = batch.emitter_count,
        };
        proxy.cmdPushConstants(cmd, layout, PipelineLayout.push_stages, 0, @sizeOf(Shader.ParticlePushConstant), &push);
        proxy.cmdDraw(cmd, 6, batch.emitter_count * effect_data.instancesPerEmitter(), 0, 0);
    }
}

fn renderDebugPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *const FrameData, list: *const DrawList) void {
    const proxy = self.device.proxy;
    if (!self.bindPipeline(cmd, .debug)) return;
    proxy.cmdSetPrimitiveTopology(cmd, .line_list);
    proxy.cmdSetDepthTestEnable(cmd, .false);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    const layout = self.resources.pipeline_layouts.get(.world).handle;
    self.bindWorldDescriptors(cmd, layout);

    const debug_vertices: [*]FrameData.DebugVertex = @ptrCast(@alignCast(current_frame.debug_vertex_buffer.mapped));
    for (list.draw_lines.items, 0..) |line, line_index| {
        debug_vertices[line_index * 2] = .{ .position = .{ line.a[0], line.a[1], line.a[2], 1 }, .color = line.color };
        debug_vertices[line_index * 2 + 1] = .{ .position = .{ line.b[0], line.b[1], line.b[2], 1 }, .color = line.color };
    }
    const push: Shader.WorldPushConstant = .{
        .vertex_buffer_address = current_frame.debug_vertex_buffer.getGPUAddress(),
        .model_matrix = nz.Mat4x4(f32).identity.d,
        .joint_matrices_address = 0,
        .texture_index = 0,
    };
    proxy.cmdPushConstants(cmd, layout, PipelineLayout.push_stages, 0, @sizeOf(Shader.WorldPushConstant), &push);
    proxy.cmdDraw(cmd, @intCast(list.draw_lines.items.len * 2), 1, 0, 0);
    proxy.cmdSetPrimitiveTopology(cmd, .triangle_list);
}

fn renderDvuiPass(self: *Vulkan, cmd: vk.CommandBuffer, current_frame: *FrameData, list: *const DrawList) void {
    if (list.dvui.commands.items.len == 0 or !self.bindPipeline(cmd, .dvui)) return;
    const proxy = self.device.proxy;
    current_frame.dvui_vertex_buffer.copy(DrawList.DvuiVertex, list.dvui.vertices.items);
    current_frame.dvui_index_buffer.copy(u32, list.dvui.indices.items);
    proxy.cmdSetCullMode(cmd, .{});
    proxy.cmdSetDepthTestEnable(cmd, .false);
    proxy.cmdSetDepthWriteEnable(cmd, .false);
    const layout = self.resources.pipeline_layouts.get(.dvui).handle;
    proxy.cmdBindDescriptorSets(cmd, .graphics, layout, 0, &.{self.resources.texture_table.set}, null);
    proxy.cmdBindIndexBuffer(cmd, current_frame.dvui_index_buffer.buffer, 0, .uint32);
    var push: Shader.DvuiPushConstant = .{
        .vertex_buffer_address = current_frame.dvui_vertex_buffer.getGPUAddress(),
        .screen_size = .{ @floatFromInt(self.swapchain.draw_image.extent.width), @floatFromInt(self.swapchain.draw_image.extent.height) },
        .texture_index = 0,
    };
    const full = self.fullScissor();
    for (list.dvui.commands.items) |command| {
        push.texture_index = @intFromEnum(command.texture);
        proxy.cmdPushConstants(cmd, layout, PipelineLayout.push_stages, 0, @sizeOf(Shader.DvuiPushConstant), &push);
        const scissor: vk.Rect2D = if (command.clip) |clip| clipped: {
            const x0 = std.math.clamp(clip.x, 0, @as(i32, @intCast(full.extent.width)));
            const y0 = std.math.clamp(clip.y, 0, @as(i32, @intCast(full.extent.height)));
            const x1 = std.math.clamp(clip.x + @as(i32, @intCast(clip.width)), x0, @as(i32, @intCast(full.extent.width)));
            const y1 = std.math.clamp(clip.y + @as(i32, @intCast(clip.height)), y0, @as(i32, @intCast(full.extent.height)));
            break :clipped .{ .offset = .{ .x = x0, .y = y0 }, .extent = .{ .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) } };
        } else full;
        if (scissor.extent.width == 0 or scissor.extent.height == 0) continue;
        proxy.cmdSetScissorWithCount(cmd, &.{scissor});
        proxy.cmdDrawIndexed(cmd, command.index_count, 1, command.index_start, 0, 0);
    }
    proxy.cmdSetScissorWithCount(cmd, &.{full});
}

fn bindWorldDescriptors(self: *Vulkan, cmd: vk.CommandBuffer, pipeline_layout: vk.PipelineLayout) void {
    const frame_index = self.frameIndex();
    const world_sets = [_]vk.DescriptorSet{
        self.resources.scene_sets[frame_index],
        self.resources.texture_table.set,
        self.resources.shadow_sets[frame_index],
    };
    self.device.proxy.cmdBindDescriptorSets(cmd, .graphics, pipeline_layout, 0, &world_sets, null);
}

fn frameIndex(self: *const Vulkan) usize {
    return self.current_frame_inflight % self.frames.len;
}

fn bindPipeline(self: *Vulkan, cmd: vk.CommandBuffer, pipeline: Shaders.Pipeline) bool {
    const handle = self.resources.shaders.get(pipeline);
    if (handle == .null_handle) return false;
    self.device.proxy.cmdBindPipeline(cmd, .graphics, handle);
    return true;
}

fn drawMesh(
    self: *Vulkan,
    cmd: vk.CommandBuffer,
    current_frame: *const FrameData,
    mesh: *const Mesh,
    surfaces: []const Mesh.Surface,
    palette_offset: ?u32,
    top_matrix: nz.Mat4x4(f32),
) void {
    const proxy = self.device.proxy;
    var push: Shader.WorldPushConstant = .{
        .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
        .model_matrix = top_matrix.d,
        .joint_matrices_address = if (palette_offset) |offset|
            current_frame.joint_buffer.getGPUAddress() + offset * @sizeOf(nz.Mat4x4(f32))
        else
            self.resources.identity_joint_buffer.getGPUAddress(),
        .texture_index = 0,
    };
    const layout = self.resources.pipeline_layouts.get(.world).handle;
    proxy.cmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, .uint32);
    for (surfaces) |surface| {
        push.texture_index = @intFromEnum(surface.texture);
        proxy.cmdPushConstants(cmd, layout, PipelineLayout.push_stages, 0, @sizeOf(Shader.WorldPushConstant), &push);
        proxy.cmdDrawIndexed(cmd, @intCast(surface.index_count), 1, surface.index_start, 0, 0);
    }
}
