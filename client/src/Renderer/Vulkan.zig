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
const max_frames_inflight: usize = 3;

pub const Model = @import("Vulkan/Model.zig");

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
current_frame_inflight: u32 = 0,
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
    _ = try self.resources.createStaticMesh(gpa, Resources.default_mesh_name, Mesh.box.verticies, Mesh.box.indicies);
    _ = try self.resources.createStaticMesh(gpa, "cube_projectile", Mesh.box.verticies, Mesh.box.indicies);
    _ = try self.resources.createExplosionParticleResources(gpa);
    try self.resources.loadEntityAssets(gpa, asset_server);
    // TEMP-COMMENT: HUD-own textures (not entity assets) — Hud declares, loader loads.
    for (system.Hud.texture_paths) |path| _ = try self.resources.loadTexture(gpa, asset_server, path);

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

    const light_time = info.elapsed_time * 0.01;
    var scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_view_proj = proj_view.inverse().d,
        .global_light_direction = .{ @cos(light_time), @sin(light_time), 0 },
        .time = elapsed_time,
        .camera_position = camera_transform.position,
        .light_color = if (info.world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{
            1, 0.5, 0.5, 1,
        },
    };
    current_frame.gpu_scene.copy(FrameData.GPUScene, (&scene_data)[0..1]);

    ext.vkCmdBeginRendering(cmd, &render_info);
    try renderWorldPass(self, cmd, current_frame, info);
    renderSkyPass(self, cmd, current_frame);
    try renderParticlePass(self, cmd, info, camera_transform);
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

        const bound = [_]c.VkShaderEXT{ self.resources.shaders.get(.vert_skinned).handle, self.resources.shaders.get(.frag_mesh).handle, null, null, null };
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

fn renderWorldPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) !void {
    // TEMP-COMMENT: [scene, texture array] bound ONCE for every world draw; emitNode no longer
    // rebinds descriptors per surface — per-draw texture choice is just a push-constant index.
    self.bindWorldDescriptors(cmd, current_frame);

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_static));
    bindFragmentShader(cmd, self.resources.shaders.getPtr(.frag_mesh));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.modelForKind(entity.kind);
        if (model.isEmpty() or model.isSkinned()) continue;
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawStatic(self, cmd, model, base_matrix);
    }

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_skinned));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.modelForKind(entity.kind);
        if (model.isEmpty() or !model.isSkinned()) continue;
        const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
        for (skeleton.joint_matrices) |*matrices| {
            matrices.gpu.copy(nz.Mat4x4(f32), matrices.cpu);
        }
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
        const handle = [_]c.VkShaderEXT{ self.resources.shaders.get(.vert_sky).handle, self.resources.shaders.get(.frag_sky).handle };
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
        // TEMP-COMMENT: sky uses its OWN pipeline layout ([scene, single-sampler]) — the world
        // layout's set 1 is the 256-array now, incompatible with the skybox's one-descriptor set.
        const sky_pipeline_layout_handle = self.resources.pipeline_layouts.get(.sky).handle;
        const buf_idx_0: u32 = 0;
        const off_0: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, sky_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, sky_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);
    }
    c.vkCmdDraw(cmd, 3, 1, 0, 0);

    // TEMP-COMMENT: sky rebound the descriptor buffers for its private set; restore the
    // world binding for the passes after this one (particles go through emitNode again).
    self.bindWorldDescriptors(cmd, current_frame);
}

fn renderParticlePass(self: *Vulkan, cmd: c.VkCommandBuffer, info: *const Info, camera_transform: nz.Transform3D(f32)) !void {
    var color_blend_enables: c.VkBool32 = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &alpha_blend_eq);
    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_static));
    bindFragmentShader(cmd, self.resources.shaders.getPtr(.frag_particle));
    {
        const model = self.resources.getModelPtr(self.resources.modelHandle(Resources.explosion_particle_name));
        if (!model.isEmpty()) {
            for (info.world.particles.items) |particle| {
                const lifetime_fraction = @max(@as(f32, 0), particle.lifetime / particle.max_lifetime);
                const scale = particle.scale * lifetime_fraction;
                var transform: nz.Transform3D(f32) = .{ .position = particle.position };
                const camera_delta = camera_transform.position - particle.position;
                const camera_distance = nz.vec.length(camera_delta);
                const card_forward: nz.Vec3(f32) = if (camera_distance > 0.001)
                    nz.vec.scale(camera_delta, 1.0 / camera_distance)
                else
                    .{ 0, 0, -1 };
                const camera_up = camera_transform.rotation.rotateVec(.{ 0, 1, 0 });
                transform.rotation = nz.Quat(f32).lookAt(card_forward, camera_up);
                transform.scale = @splat(scale);
                try drawStatic(self, cmd, model, transform.toMat4x4());
            }
        }
    }
    color_blend_enables = c.VK_FALSE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
}

fn renderDebugPass(self: *Vulkan, cmd: c.VkCommandBuffer, current_frame: *const FrameData, info: *const Info) !void {
    if (!info.world.controller.debug_draw_colliders) return;

    const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
    const handles = [_]c.VkShaderEXT{ self.resources.shaders.get(.vert_debug).handle, self.resources.shaders.get(.frag_debug).handle };
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
        const collider_shape = shared.entity.colliderShape(entity.kind) orelse continue;
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
        self.resources.shaders.get(.vert_ui).handle,
        self.resources.shaders.get(.frag_ui).handle,
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

// TEMP-COMMENT: was: rebind scene+material descriptor buffers PER SURFACE (two bind calls +
// two offset calls per submesh, every draw, every frame). Now descriptors are bound once per
// frame (bindWorldDescriptors) and a surface is just: index into the texture array + draw.
fn emitNode(
    self: *Vulkan,
    cmd: c.VkCommandBuffer,
    mesh: *Mesh,
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
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, world_bindings.len, &world_bindings[0]);
    const buf_idx_0: u32 = 0;
    const off_0: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
    const buf_idx_1: u32 = 1;
    const off_1: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);
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

pub fn drainRenderCommands(self: *Vulkan, gpa: std.mem.Allocator, world: *World) !void {
    for (world.render_outbox.items) |command| switch (command) {
        .entity_spawned => |spawned| try self.ensureSkeleton(gpa, spawned.id, spawned.kind),
        .entity_despawned => |id| self.removeSkeleton(gpa, id),
        .planet_spawned => |radius| try self.buildPlanet(gpa, radius),
    };
    world.render_outbox.clearRetainingCapacity();
}

fn buildPlanet(self: *Vulkan, gpa: std.mem.Allocator, radius: u32) !void {
    var planet: shared.Planet(.renderable) = try .init(gpa, radius);
    defer planet.deinit(gpa);
    // TEMP-COMMENT: registerModel dedupe means this rebuild lands at the same handle
    // entity_models.planet resolved at init — nothing to re-point.
    _ = try self.resources.createStaticMesh(gpa, "planet", planet.vertices, planet.indices);
}

fn ensureSkeleton(self: *Vulkan, gpa: std.mem.Allocator, entity_id: shared.entity.Id, entity_kind: shared.entity.Kind) !void {
    if (self.skeletons.contains(entity_id)) return;
    const model = self.resources.modelForKind(entity_kind);
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
        f / aspect, 0,  0,                           0,
        0,          -f, 0,                           0, // flip Y for Vulkan
        0,          0,  far / (near - far),          -1,
        0,          0,  (far * near) / (near - far), 0,
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
