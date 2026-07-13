const std = @import("std");
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
const Material = @import("Vulkan/Material.zig");
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
const menu_planet_radius: f32 = 18;

pub const Model = @import("Vulkan/Model.zig");

gpa: std.mem.Allocator,

instance: Instance,
debug_messenger: DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
vma: Vma,
swapchain: Swapchain,
resources: *Resources,
skeletons: std.AutoHashMap(shared.entity.Id, SkeletonInstance),
menu_player: SkeletonInstance,
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

pub fn init(gpa: std.mem.Allocator, asset_server: *AssetServer, options: InitOptions) !*@This() {
    const self = try gpa.create(@This());
    self.gpa = gpa;
    self.skeletons = .init(gpa);

    self.instance = try .init(gpa, options.instance.extensions, options.instance.layers);
    procs.instance.load(self.instance.handle, null);
    self.debug_messenger = try .init(self.instance, .{
        .severities = if (try std.process.Environ.contains(.empty, gpa, "RENDERDOC_CAPFILE")) .{} else .{
            .warning = true,
            .verbose = true,
            .@"error" = true,
            .info = true,
        },
    });
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
    try self.resources.createStaticMesh(gpa, Resources.default_mesh_name, Mesh.box.verticies, Mesh.box.indicies, .unknown);
    try self.resources.createStaticMesh(gpa, "bullet", Mesh.box.verticies, Mesh.box.indicies, .bullet);
    const menu_planet = try shared.Planet(.renderable).init(gpa, 18);
    defer menu_planet.deinit(gpa);
    try self.resources.createStaticMesh(gpa, "menu_planet", menu_planet.vertices, menu_planet.indices, .menu_planet);
    self.menu_player = try .init(gpa, self.vma, self.device, self.resources.models.getPtr(.player));

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

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};

    self.menu_player.deinit(gpa, self.vma);
    self.resources.deinit(gpa, self.vma, self.device);

    var it = self.skeletons.valueIterator();
    while (it.next()) |skeleton| {
        skeleton.deinit(gpa, self.vma);
    }
    self.skeletons.deinit();

    self.ui.deinit(gpa, self.vma);
    for (&self.frames) |*frame| frame.deinit(self.vma, self.device);
    self.swapchain.deinit(self.vma, self.device);
    self.vma.deinit();
    self.device.deinit();
    self.surface.deinit(self.instance);
    self.debug_messenger.deinit(self.instance);
    self.instance.deinit();
}

pub fn rebindProcs(self: *@This()) void {
    procs.instance.load(self.instance.handle, null);
    procs.device.load(self.device.handle, null);
}

pub fn update(self: *@This(), info: *const Info) !void {
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

pub fn render(self: *@This(), cmd: c.VkCommandBuffer, current_frame: *FrameData, info: *const Info) !void {
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

    var color_blend_enables: c.VkBool32 = c.VK_FALSE;
    const color_blend_component_flags: c.VkColorComponentFlags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorWriteMaskEXT(cmd, 0, 1, &color_blend_component_flags);

    ext.vkCmdSetDepthBoundsTestEnable(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthClampEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetAlphaToOneEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetLogicOpEnableEXT(cmd, c.VK_FALSE);

    ext.vkCmdSetVertexInputEXT(cmd, 0, null, 0, null);

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

    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    const aspect: f32 = width / height;

    const gameplay_camera = info.world.camera;
    const menu_tuning = info.world.menu_tuning;
    const menu_camera_transform = menuCameraTransform(menu_tuning);
    const camera_transform = if (info.world.show_menu_scene) menu_camera_transform else gameplay_camera.transform;
    const view = getViewMatrix(&camera_transform);
    const fov_rad: f32 = if (info.world.show_menu_scene) menu_tuning.fov_rad else gameplay_camera.fov_rad;
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

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_static));
    bindFragmentShader(cmd, self.resources.shaders.getPtr(.frag_mesh));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.models.getPtr(.fromKind(entity.kind));
        if (model.isEmpty() or model.isSkinned()) continue;
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawStatic(self, cmd, model, current_frame, base_matrix);
    }

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_skinned));
    for (info.world.entities.values()) |*entity| {
        const model = self.resources.models.getPtr(.fromKind(entity.kind));
        if (model.isEmpty() or !model.isSkinned()) continue;
        const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
        for (skeleton.joint_matrices) |*matrices| {
            matrices.gpu.copy(nz.Mat4x4(f32), matrices.cpu);
        }
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawSkeletal(self, cmd, skeleton, current_frame, base_matrix);
    }
    if (info.world.show_menu_scene) {
        try drawMenuScene(self, cmd, current_frame, elapsed_time, camera_transform, aspect, menu_tuning);
    }

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
            .address = self.resources.getMaterialPtr(self.resources.skybox_material_index).buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, sky_bindings.len, &sky_bindings[0]);
    {
        const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
        const buf_idx_0: u32 = 0;
        const off_0: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);
    }
    c.vkCmdDraw(cmd, 3, 1, 0, 0);

    if (info.world.controller.debug_draw_colliders) {
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
            var push: Shader.StaticPushConstant = .{
                .vertex_buffer_address = current_frame.debug_vertex_buffer.getGPUAddress(),
                .model_matrix = collider_transform.toMat4x4().d,
            };
            c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Shader.StaticPushConstant), &push);
            c.vkCmdDraw(cmd, debug_vertex_count - first_vertex, 1, first_vertex, 0);
        }
        ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    }

    current_frame.ui_vertex_buffer.copy(Ui.Quad, self.ui.quads.items);
    var stages_ui = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const bounds_ui = [_]c.VkShaderEXT{
        self.resources.shaders.get(.vert_ui).handle,
        self.resources.shaders.get(.frag_ui).handle,
    };

    ext.vkCmdBindShadersEXT(cmd, 2, &stages_ui[0], &bounds_ui[0]);

    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_FALSE);
    color_blend_enables = c.VK_TRUE;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    const blend_eq: c.VkColorBlendEquationEXT = .{
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
    };
    ext.vkCmdSetColorBlendEquationEXT(cmd, 0, 1, &blend_eq);
    const ui_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = self.resources.ui_texture_buffer.getGPUAddress(),
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
    c.vkCmdPushConstants(cmd, ui_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Shader.UiPushConstant), &push);
    c.vkCmdBindIndexBuffer(cmd, self.ui.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(cmd, @as(u32, @intCast(self.ui.quads.items.len * 6)), 1, 0, 0, 0);
    ext.vkCmdEndRendering(cmd);

    draw_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_READ_BIT);
}

fn drawStatic(
    self: *@This(),
    cmd: c.VkCommandBuffer,
    model: *const Model,
    current_frame: *const FrameData,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (model.surfaces.items) |surface| {
        const mesh = self.resources.getMeshPtr(surface.mesh_id);
        const surface_matrix = top_matrix.mul(surface.model_matrix);
        var push: Shader.StaticPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = surface_matrix.d,
        };
        try emitNode(self, cmd, current_frame, mesh, &push);
    }
}

fn drawSkeletal(
    self: *@This(),
    cmd: c.VkCommandBuffer,
    skeleton: *const SkeletonInstance,
    current_frame: *const FrameData,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (skeleton.nodes) |node| {
        const mesh_id = node.mesh_id orelse continue;
        const mesh = self.resources.getMeshPtr(mesh_id);
        var push: Shader.AnimationPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = if (node.skin_id != null) top_matrix.d else top_matrix.mul(node.model_matrix).d,
            .joint_matrices_address = if (node.skin_id) |skin_index|
                skeleton.joint_matrices[skin_index].gpu.getGPUAddress()
            else
                0,
        };
        try emitNode(self, cmd, current_frame, mesh, &push);
    }
}

fn drawMenuScene(self: *@This(), cmd: c.VkCommandBuffer, current_frame: *const FrameData, elapsed_time: f32, camera_transform: nz.Transform3D(f32), aspect: f32, tuning: World.MenuTuning) !void {
    const planet_position = tuning.planet_position;
    const camera_right = camera_transform.rotation.rotateVec(.{ 1, 0, 0 });
    const roll_axis = nz.vec.normalize(camera_right);
    const planet_transform: nz.Transform3D(f32) = .{
        .position = planet_position,
        .rotation = nz.Quat(f32).angleAxis(elapsed_time * 0.22, roll_axis),
        .scale = @splat(tuning.planet_scale),
    };

    const screen_ray = menuRayFromScreen(camera_transform, tuning.fov_rad, aspect, tuning.bozo_screen);
    const bozo_ray = menuBozoRayToPlanetCenter(screen_ray, planet_transform);
    const surface = raycastMenuPlanet(bozo_ray.origin, bozo_ray.direction, planet_transform) orelse fallbackMenuPlanetHit(bozo_ray.origin, planet_transform);
    const planet_up = menuPlanetUp(surface.position, planet_transform);
    const player_position = surface.position + nz.vec.scale(planet_up, tuning.bozo_surface_offset);
    const to_camera = camera_transform.position - player_position;
    const camera_on_tangent = to_camera - nz.vec.scale(planet_up, nz.vec.dot(to_camera, planet_up));
    const surface_forward_raw = nz.vec.cross(roll_axis, planet_up);
    const surface_forward = if (nz.vec.length(surface_forward_raw) > 0.001)
        nz.vec.normalize(surface_forward_raw)
    else
        nz.vec.normalize(camera_on_tangent);
    const player_rotation = nz.Quat(f32).lookAt(surface_forward, planet_up);

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_static));
    bindFragmentShader(cmd, self.resources.shaders.getPtr(.frag_mesh));
    const planet_model = self.resources.models.getPtr(.menu_planet);
    try drawStatic(self, cmd, planet_model, current_frame, planet_transform.toMat4x4().mul(planet_model.offset.toMat4x4()));

    bindVertexShader(cmd, self.resources.shaders.getPtr(.vert_skinned));
    updateMenuPlayer(self, elapsed_time);
    for (self.menu_player.joint_matrices) |*matrices| {
        matrices.gpu.copy(nz.Mat4x4(f32), matrices.cpu);
    }
    const player_transform: nz.Transform3D(f32) = .{
        .position = player_position,
        .rotation = player_rotation,
        .scale = @splat(tuning.player_scale),
    };
    const player_model = self.resources.models.getPtr(.player);
    try drawSkeletal(self, cmd, &self.menu_player, current_frame, player_transform.toMat4x4().mul(player_model.offset.toMat4x4()));
}

const MenuRay = struct {
    origin: nz.Vec3(f32),
    direction: nz.Vec3(f32),
};

const MenuPlanetHit = struct {
    position: nz.Vec3(f32),
    normal: nz.Vec3(f32),
};

fn menuCameraTransform(tuning: World.MenuTuning) nz.Transform3D(f32) {
    const pitch = std.math.clamp(tuning.camera_pitch, -1.2, 0.6);
    const cos_pitch = @cos(pitch);
    const forward: nz.Vec3(f32) = nz.vec.normalize(@as(nz.Vec3(f32), .{
        @sin(tuning.camera_yaw) * cos_pitch,
        @sin(pitch),
        -@cos(tuning.camera_yaw) * cos_pitch,
    }));
    return .{
        .position = tuning.camera_target - nz.vec.scale(forward, tuning.camera_distance),
        .rotation = nz.Quat(f32).lookAt(forward, @as(nz.Vec3(f32), .{ 0, 1, 0 })),
    };
}

fn menuRayFromScreen(camera_transform: nz.Transform3D(f32), fov_rad: f32, aspect: f32, screen_position: [2]f32) MenuRay {
    const ndc_x = screen_position[0] * 2 - 1;
    const ndc_y = 1 - screen_position[1] * 2;
    const tan_half_fov = @tan(fov_rad * 0.5);
    const local_direction: nz.Vec3(f32) = nz.vec.normalize(@as(nz.Vec3(f32), .{
        ndc_x * aspect * tan_half_fov,
        ndc_y * tan_half_fov,
        -1,
    }));
    return .{
        .origin = camera_transform.position,
        .direction = nz.vec.normalize(camera_transform.rotation.rotateVec(local_direction)),
    };
}

fn menuBozoRayToPlanetCenter(screen_ray: MenuRay, planet_transform: nz.Transform3D(f32)) MenuRay {
    const center = planet_transform.position;
    const center_to_ray_origin = center - screen_ray.origin;
    const closest_distance = @max(@as(f32, 0), nz.vec.dot(center_to_ray_origin, screen_ray.direction));
    const closest_point = screen_ray.origin + nz.vec.scale(screen_ray.direction, closest_distance);
    var radial = closest_point - center;
    if (nz.vec.length(radial) < 0.001) {
        radial = screen_ray.origin - center;
    }
    radial = nz.vec.normalize(radial);

    const start_radius = menu_planet_radius * planet_transform.scale[0] + 36;
    const origin = center + nz.vec.scale(radial, start_radius);
    return .{
        .origin = origin,
        .direction = nz.vec.normalize(center - origin),
    };
}

fn raycastMenuPlanet(origin: nz.Vec3(f32), direction: nz.Vec3(f32), planet_transform: nz.Transform3D(f32)) ?MenuPlanetHit {
    var distance: f32 = 0.1;
    for (0..96) |_| {
        if (distance > 180) return null;
        const position = origin + nz.vec.scale(direction, distance);
        const surface_distance = menuPlanetSdf(position, planet_transform);
        if (@abs(surface_distance) < 0.035) {
            return .{
                .position = position,
                .normal = menuPlanetUp(position, planet_transform),
            };
        }
        distance += @max(surface_distance, 0.05);
    }
    return null;
}

fn fallbackMenuPlanetHit(camera_position: nz.Vec3(f32), planet_transform: nz.Transform3D(f32)) MenuPlanetHit {
    const normal = nz.vec.normalize(camera_position - planet_transform.position);
    const radius = menu_planet_radius * planet_transform.scale[0];
    const position = planet_transform.position + nz.vec.scale(normal, radius);
    return .{ .position = position, .normal = normal };
}

fn menuPlanetUp(position: nz.Vec3(f32), planet_transform: nz.Transform3D(f32)) nz.Vec3(f32) {
    return nz.vec.normalize(position - planet_transform.position);
}

fn menuPlanetSdf(position: nz.Vec3(f32), planet_transform: nz.Transform3D(f32)) f32 {
    const scale = planet_transform.scale[0];
    const inv_rotation = planet_transform.rotation.conjugate();
    const local_position = nz.vec.scale(inv_rotation.rotateVec(position - planet_transform.position), 1 / scale);
    return shared.planetSdf(local_position, menu_planet_radius) * scale;
}

fn menuPlanetNormal(position: nz.Vec3(f32), planet_transform: nz.Transform3D(f32)) nz.Vec3(f32) {
    const eps: f32 = 0.15;
    const x: nz.Vec3(f32) = .{ eps, 0, 0 };
    const y: nz.Vec3(f32) = .{ 0, eps, 0 };
    const z: nz.Vec3(f32) = .{ 0, 0, eps };
    return nz.vec.normalize(@as(nz.Vec3(f32), .{
        menuPlanetSdf(position + x, planet_transform) - menuPlanetSdf(position - x, planet_transform),
        menuPlanetSdf(position + y, planet_transform) - menuPlanetSdf(position - y, planet_transform),
        menuPlanetSdf(position + z, planet_transform) - menuPlanetSdf(position - z, planet_transform),
    }));
}

fn updateMenuPlayer(self: *@This(), elapsed_time: f32) void {
    const model = self.menu_player.model;
    if (model.clips.len > 0) {
        const clip_index = model.state_clips.get(.walk);
        const animation = model.clips[clip_index];
        const duration = animation.end - animation.start;
        const animation_time = if (duration > 0) animation.start + @mod(elapsed_time, duration) else animation.start;
        sampleClip(self.menu_player.nodes, animation, animation_time);
        if (model.nodes.items.len > 0 and self.menu_player.nodes.len > 0) {
            self.menu_player.nodes[0].translation = model.nodes.items[0].translation;
        }
    }
    Model.computeMatrices(self.menu_player.nodes);
    for (model.skins, self.menu_player.joint_matrices) |skin, joint_matrices| {
        for (skin.joints, skin.inverse_bind_matrices.?, joint_matrices.cpu) |node_index, inverse_bind_matrix, *joint_matrix| {
            joint_matrix.* = self.menu_player.nodes[node_index].model_matrix.mul(inverse_bind_matrix);
        }
    }
}

fn sampleClip(nodes: []Node, animation: AnimationClip, time: f32) void {
    for (animation.channels) |*channel| {
        const sampler = animation.samplers[channel.sampler_index];
        if (sampler.inputs.len < 2) continue;
        for (0..sampler.inputs.len - 1) |i| {
            const sampler_in = sampler.inputs[i];
            const sampler_in_next = sampler.inputs[i + 1];
            if (time >= sampler_in and time <= sampler_in_next) {
                const interpolate_value: f32 = (time - sampler_in) / (sampler_in_next - sampler_in);
                const node = &nodes[channel.node];
                const sampler_out = sampler.outputs[i];
                const sampler_out_next = sampler.outputs[i + 1];
                switch (channel.path) {
                    .translation => {
                        const translation = std.math.lerp(
                            sampler_out,
                            sampler_out_next,
                            @as(nz.Vec4(f32), @splat(interpolate_value)),
                        );
                        node.translation = .{ translation[0], translation[1], translation[2] };
                    },
                    .rotation => node.rotation = nz.Quat(f32).slerp(
                        .{ .w = sampler_out[3], .x = sampler_out[0], .y = sampler_out[1], .z = sampler_out[2] },
                        .{ .w = sampler_out_next[3], .x = sampler_out_next[0], .y = sampler_out_next[1], .z = sampler_out_next[2] },
                        interpolate_value,
                    ),
                    .scale => {
                        const scale = std.math.lerp(
                            sampler_out,
                            sampler_out_next,
                            @as(nz.Vec4(f32), @splat(interpolate_value)),
                        );
                        node.scale = .{ scale[0], scale[1], scale[2] };
                    },
                }
            }
        }
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
    self: *@This(),
    cmd: c.VkCommandBuffer,
    current_frame: *const FrameData,
    mesh: *Mesh,
    push: anytype,
) !void {
    const world_pipeline_layout_handle = self.resources.pipeline_layouts.get(.world).handle;
    c.vkCmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdPushConstants(cmd, world_pipeline_layout_handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@typeInfo(@TypeOf(push)).pointer.child), push);
    for (mesh.surfaces.items) |surface| {
        const material = self.resources.getMaterialPtr(surface.material_index);
        const surface_bindings = [_]c.VkDescriptorBufferBindingInfoEXT{
            .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
                .address = current_frame.gpu_scene.getGPUAddress(),
                .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
                .address = material.buffer.getGPUAddress(),
                .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                    c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
            },
        };
        ext.vkCmdBindDescriptorBuffersEXT(cmd, surface_bindings.len, &surface_bindings[0]);

        const buf_idx_0: u32 = 0;
        const off_0: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, world_pipeline_layout_handle, 1, 1, &buf_idx_1, &off_1);

        c.vkCmdDrawIndexed(cmd, @intCast(surface.index_count), 1, surface.index_start, 0, 0);
    }
}

pub fn resize(self: *@This(), gpa: std.mem.Allocator, width: u32, height: u32) !void {
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

pub fn attachSkeleton(self: *@This(), gpa: std.mem.Allocator, entity_id: shared.entity.Id, entity_kind: shared.entity.Kind) !void {
    const model = self.resources.models.getPtr(.fromKind(entity_kind));
    if (model.isEmpty() and entity_kind.expectsModel()) {
        std.debug.panic("no model registered for {s}", .{@tagName(entity_kind)});
    }
    if (!model.isSkinned()) return; // static/modelless: no skeleton
    try self.skeletons.put(entity_id, try .init(gpa, self.vma, self.device, model));
}

pub fn removeSkeleton(self: *@This(), gpa: std.mem.Allocator, entity_id: shared.entity.Id) void {
    if (self.skeletons.fetchRemove(entity_id)) |kv| {
        var skeleton = kv.value;
        skeleton.deinit(gpa, self.vma);
    }
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
        0, -f, 0, 0, // flip Y for Vulkan
        0, 0, far / (near - far),          -1, // <- note near-far here
        0, 0, (far * near) / (near - far), 0,
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
