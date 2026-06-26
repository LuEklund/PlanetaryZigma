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
const SkeletalMesh = @import("Vulkan/SkeletalMesh.zig");
const StaticMesh = @import("Vulkan/StaticMesh.zig");
const gltf = @import("Vulkan/gltf.zig");
const SkeletonInstance = @import("Vulkan/SkeletonInstance.zig");
const Vma = @import("Vulkan/Vma.zig");
const Swapchain = @import("Vulkan/Swapchain.zig");
const FrameData = @import("Vulkan/FrameData.zig");
const Surface = @import("Vulkan/Surface.zig");
const Image = @import("Vulkan/Image.zig");
const Font = @import("Vulkan/Font.zig");
const Buffer = @import("Vulkan/Buffer.zig");
const descriptor = @import("Vulkan/desrciptor.zig");
const RenderResources = @import("Vulkan/RenderResources.zig");
const pipeline = @import("Vulkan/pipeline.zig");
const Shader = @import("Vulkan/Shader.zig");
const Ui = @import("Vulkan/Ui.zig");
const procs = @import("Vulkan/procs.zig");
const ext = procs.device.ProcTable;
const tracy = @import("ztracy");

const check = @import("Vulkan/utils.zig").check;

pub const Info = system.Info;
pub const c = @import("vulkan");
const max_frames_inflight: usize = 3;

pub const Renderable = union(enum) {
    static: *StaticMesh,
    skeletal: *SkeletalMesh,
};

gpa: std.mem.Allocator,
asset_server: *AssetServer,

instance: Instance,
debug_messenger: DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
vma: Vma,
swapchain: Swapchain,
render_resources: RenderResources,
renderables: std.EnumMap(shared.Entity.Kind, Renderable),
skeletons: std.AutoHashMap(u32, SkeletonInstance),
current_frame_inflight: u32 = 0,
frames: [max_frames_inflight]FrameData,
ui: Ui,

//Temporary
vertex_shader: *Shader,
static_vertex_shader: *Shader,
fragment_shader: *Shader,
ui_vertex_shader: *Shader,
ui_fragment_shader: *Shader,
sky_fragment_shader: *Shader,
sky_vertex_shader: *Shader,
scene_layout: descriptor.Layout,
material_layout: descriptor.Layout,
ui_pipeline_layout: pipeline.Layout,
pipeline_layout: pipeline.Layout,
font: *Font,
skybox: Image,
sky_material: Material,

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
    self.asset_server = asset_server;
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

    self.scene_layout = try .init(self.device, &.{
        .{
            .binding = 0,
            .descriptorCount = @sizeOf(FrameData.GPUScene),
            .descriptorType = c.VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        },
    }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT);
    self.material_layout = try .init(self.device, &.{
        .{
            .binding = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImmutableSamplers = null,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        },
    }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT);

    self.render_resources = try .init(gpa, self.vma, self.physical_device, self.device, self.material_layout);

    self.font = try .init(
        gpa,
        self.vma,
        self.device,
        "fonts/Roboto-Regular.ttf",
        asset_server,
        &self.render_resources,
    );

    self.ui = try .init(
        gpa,
        self.vma,
        self.device,
        self.swapchain.extent.width,
        self.swapchain.extent.height,
        self.font,
    );

    self.pipeline_layout = try .init(
        self.device,
        Shader.AnimationPushConstant,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );

    self.ui_pipeline_layout = try .init(
        self.device,
        Shader.UiPushConstant,
        &.{self.material_layout.handle},
    );
    self.renderables = .{};
    const Spec = struct { path: ?[]const u8, offset: nz.Transform3D(f32), skinned: bool };
    const specs = std.EnumArray(shared.Entity.Kind, Spec).init(.{
        .planet = .{ .path = null, .offset = .{}, .skinned = false }, //comes from server
        .unknown = .{ .path = null, .offset = .{}, .skinned = false },
        .bullet = .{ .path = null, .offset = .{}, .skinned = false },
        .player = .{ .path = "objects/BenRun.glb", .offset = .{ .position = .{ 0, -1, 0 }, .rotation = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 }) }, .skinned = true },
        .teleporter = .{ .path = "objects/pillar.glb", .offset = .{}, .skinned = false },
        .skelly = .{ .path = "objects/Skelly.glb", .offset = .{ .position = .{ 0, -0.6, 0 }, .rotation = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 }) }, .skinned = true },
        .wizard = .{ .path = "objects/Wizard.glb", .offset = .{ .position = .{ 0, -0.6, 0 }, .rotation = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 }) }, .skinned = true },
        .health_item = .{ .path = "objects/health.glb", .offset = .{}, .skinned = false },
        .speed_item = .{ .path = "objects/speed.glb", .offset = .{}, .skinned = false },
        .damage_item = .{ .path = "objects/damage.glb", .offset = .{}, .skinned = false },
        .attack_speed_item = .{ .path = "objects/attack_speed.glb", .offset = .{}, .skinned = false },
    });
    for (std.enums.values(shared.Entity.Kind)) |kind| {
        const spec = specs.get(kind);
        const path = spec.path orelse continue;
        const renderable: Renderable = if (spec.skinned)
            .{ .skeletal = try SkeletalMesh.load(self.gpa, self.vma, self.device, self.asset_server, &self.render_resources, path, spec.offset) }
        else
            .{ .static = try StaticMesh.load(self.gpa, self.vma, self.device, self.asset_server, &self.render_resources, path, spec.offset) };
        self.renderables.put(kind, renderable);
    }
    try self.createStaticMesh(gpa, RenderResources.default_mesh_name, Mesh.box.verticies, Mesh.box.indicies, .unknown);
    try self.createStaticMesh(gpa, "bullet", Mesh.box.verticies, Mesh.box.indicies, .bullet);

    self.vertex_shader = try self.createShader(
        "shaders/animation.vert",
        Shader.AnimationPushConstant,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );
    self.static_vertex_shader = try self.createShader(
        "shaders/static.vert",
        Shader.AnimationPushConstant,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );
    self.fragment_shader = try self.createShader(
        "shaders/fragment.frag",
        Shader.AnimationPushConstant,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );
    self.ui_vertex_shader = try self.createShader(
        "shaders/ui.vert",
        Shader.UiPushConstant,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        &.{self.material_layout.handle},
    );
    self.ui_fragment_shader = try self.createShader(
        "shaders/ui.frag",
        Shader.UiPushConstant,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        &.{self.material_layout.handle},
    );
    self.sky_fragment_shader = try self.createShader(
        "shaders/sky.frag",
        void,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );
    self.sky_vertex_shader = try self.createShader(
        "shaders/sky.vert",
        void,
        c.VK_SHADER_STAGE_VERTEX_BIT,
        &.{ self.scene_layout.handle, self.material_layout.handle },
    );

    var decoded_images = try gpa.alloc(gltf.DecodedImage, 1);
    defer {
        for (decoded_images) |*decoded_image| decoded_image.deinit();
        gpa.free(decoded_images);
    }
    @memset(decoded_images, .{});

    var decode_tasks = try gpa.alloc(gltf.ImageDecodeTask, 1);
    defer {
        gpa.free(decode_tasks);
    }

    decode_tasks[0] = .{ .result = &decoded_images[0] };
    decode_tasks[0].uri = "assets/textures/skybox_cubemap.png";

    try gltf.decodeImages(gpa, decode_tasks);

    const width: u32 = @intCast(decoded_images[0].width);
    const face_size: u32 = @divTrunc(width, 4);
    std.log.debug("res: {d}, face. {d}", .{ decoded_images[0].width, face_size });

    self.skybox = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{
            .width = face_size,
            .height = face_size,
            .depth = 1,
        },
        .cube_map,
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    const channels: u32 = @intCast(decoded_images[0].nr_channel);
    const row_bytes = face_size * channels;
    const data = try gpa.alloc(u8, face_size * face_size * channels);
    defer gpa.free(data);
    for (0..6) |i| {
        var x_start: u32, var y_start: u32 = switch (i) {
            0 => .{ 2, 1 },
            1 => .{ 0, 1 },
            2 => .{ 1, 0 },
            3 => .{ 1, 2 },
            4 => .{ 1, 1 },
            5 => .{ 3, 1 },
            else => unreachable,
        };
        x_start *= face_size;
        y_start *= face_size;

        for (0..face_size) |y| {
            const dst = y * row_bytes;
            const src = ((y_start + y) * width + x_start) * channels;
            @memcpy(data[dst..][0..row_bytes], decoded_images[0].pixels[src..][0..row_bytes]);
        }

        try self.skybox.uploadDataToImage(
            self.vma,
            self.device,
            data,
            channels,
            @intCast(i),
        );
        // std.log.debug("sizes x: {d}, y: {d}", .{ x, y });
    }
    self.sky_material = try .init(
        gpa,
        "skybox",
        self.device,
        self.vma,
        self.render_resources.set_size,
        self.render_resources.combined_image_sampler_descriptor_size,
        self.render_resources.samplers.items[0],
        self.skybox.vk_imageview,
    );

    return self;
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};

    self.render_resources.deinit(gpa, self.vma, self.device);

    var model_it = self.renderables.iterator();
    while (model_it.next()) |entry| switch (entry.value.*) {
        .static => |model| model.deinit(gpa),
        .skeletal => |model| model.deinit(gpa),
    };
    var it = self.skeletons.valueIterator();
    while (it.next()) |skeleton| {
        skeleton.deinit(gpa, self.vma);
    }
    self.skeletons.deinit();

    self.material_layout.deinit(self.device);
    self.scene_layout.deinit(self.device);
    self.pipeline_layout.deinit(self.device);
    self.ui_pipeline_layout.deinit(self.device);
    self.vertex_shader.deinit(gpa);
    self.static_vertex_shader.deinit(gpa);
    self.fragment_shader.deinit(gpa);
    self.ui_fragment_shader.deinit(gpa);
    self.sky_fragment_shader.deinit(gpa);
    self.sky_vertex_shader.deinit(gpa);
    self.skybox.deinit(self.vma, self.device);
    self.sky_material.deinit(self.gpa, self.vma);
    self.ui_vertex_shader.deinit(gpa);
    self.ui.deinit(gpa, self.vma);
    self.font.deinit(gpa, self.vma, self.device);
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

        const bound = [_]c.VkShaderEXT{ self.vertex_shader.handle, self.fragment_shader.handle, null, null, null };
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
    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_TRUE);
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

    const camera = info.world.camera;
    const width: f32 = @floatFromInt(self.swapchain.draw_image.extent.width);
    const height: f32 = @floatFromInt(self.swapchain.draw_image.extent.height);
    const aspect: f32 = width / height;

    const view = getViewMatrix(&camera.transform);
    var proj = perspective(camera.fov_rad, aspect, 0.01, 1000);
    const proj_view = proj.mul(view);

    var scene_data: FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .inverse_view_proj = proj_view.inverse().d,
        .global_light_direction = .{ @cos(info.elapsed_time), @sin(info.elapsed_time), 0 },
        .time = elapsed_time,
        .camera_position = camera.transform.position,
        .light_color = if (info.world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{
            1, 0.5, 0.5, 1,
        },
    };
    current_frame.gpu_scene.copy(FrameData.GPUScene, (&scene_data)[0..1]);

    ext.vkCmdBeginRendering(cmd, &render_info);

    bindVertexShader(cmd, self.static_vertex_shader);
    for (info.world.entities.values()) |*entity| {
        const renderable = self.renderables.get(entity.kind) orelse {
            if (entity.kind.expectsModel()) {
                std.log.err("no model registered for {s}", .{@tagName(entity.kind)});
                return error.NoModel;
            }
            continue; // bullet/unknown: intentionally modelless
        };
        const model = switch (renderable) {
            .static => |static_model| static_model,
            .skeletal => continue,
        };
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        try drawStatic(self, cmd, model, current_frame, base_matrix);
    }

    bindVertexShader(cmd, self.vertex_shader);
    for (info.world.entities.values()) |*entity| {
        const renderable = self.renderables.get(entity.kind) orelse continue;
        const model = switch (renderable) {
            .skeletal => |skeletal_model| skeletal_model,
            .static => continue,
        };
        const skeleton = self.skeletons.getPtr(entity.id) orelse continue;
        const base_matrix = entity.transform.toMat4x4().mul(model.offset.toMat4x4());
        for (model.top_nodes.items) |top_node_id| {
            try drawSkeletal(self, cmd, skeleton, current_frame, top_node_id, base_matrix);
        }
    }

    ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_NONE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    {
        const stages = [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const handle = [_]c.VkShaderEXT{ self.sky_vertex_shader.handle, self.sky_fragment_shader.handle };
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
            .address = self.sky_material.buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, sky_bindings.len, &sky_bindings[0]);
    {
        const buf_idx_0: u32 = 0;
        const off_0: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout.handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout.handle, 1, 1, &buf_idx_1, &off_1);
    }
    c.vkCmdDraw(cmd, 3, 1, 0, 0);

    current_frame.ui_vertex_buffer.copy(Ui.Quad, self.ui.quads.items);
    var stages_ui = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const bounds_ui = [_]c.VkShaderEXT{
        self.ui_vertex_shader.handle,
        self.ui_fragment_shader.handle,
    };

    ext.vkCmdBindShadersEXT(cmd, 2, &stages_ui[0], &bounds_ui[0]);

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
            .address = self.font.material.buffer.getGPUAddress(),
            .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
        },
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, 1, &ui_bindings[0]);

    const buf_idx_0: u32 = 0;
    const off_0: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.ui_pipeline_layout.handle, 0, 1, &buf_idx_0, &off_0);

    var push: Shader.UiPushConstant = .{
        .vertex_buffer_address = current_frame.ui_vertex_buffer.getGPUAddress(),
        .screnn_size = .{ width, height },
    };
    c.vkCmdPushConstants(cmd, self.ui_pipeline_layout.handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Shader.UiPushConstant), &push);
    c.vkCmdBindIndexBuffer(cmd, self.ui.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(cmd, @as(u32, @intCast(self.ui.quads.items.len * 6)), 1, 0, 0, 0);
    ext.vkCmdEndRendering(cmd);

    draw_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_READ_BIT);
}

fn drawStatic(
    self: *@This(),
    cmd: c.VkCommandBuffer,
    model: *const StaticMesh,
    current_frame: *const FrameData,
    top_matrix: nz.Mat4x4(f32),
) !void {
    for (model.surfaces.items) |surface| {
        const mesh = try self.render_resources.getMeshPtr(surface.mesh_id);
        const surface_matrix = top_matrix.mul(surface.local_matrix);
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
    node_id: usize,
    top_matrix: nz.Mat4x4(f32),
) !void {
    const node = skeleton.nodes[node_id];
    const node_matrix = top_matrix.mul(node.world_matrix);

    if (node.mesh_id) |mesh_id| {
        const mesh = try self.render_resources.getMeshPtr(mesh_id);
        var push: Shader.AnimationPushConstant = .{
            .vertex_buffer_address = mesh.vertex_buffer.getGPUAddress(),
            .model_matrix = node_matrix.d,
            .inverse_bind_matrices_addess = if (node.skin_id >= 0)
                skeleton.buffers[@intCast(node.skin_id)].getGPUAddress()
            else
                0,
        };
        try emitNode(self, cmd, current_frame, mesh, &push);
    }

    for (node.children.items) |child_id| {
        try drawSkeletal(self, cmd, skeleton, current_frame, child_id, node_matrix);
    }
}

fn bindVertexShader(cmd: c.VkCommandBuffer, shader: *Shader) void {
    const stage = [_]c.VkShaderStageFlagBits{c.VK_SHADER_STAGE_VERTEX_BIT};
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
    c.vkCmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdPushConstants(cmd, self.pipeline_layout.handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@typeInfo(@TypeOf(push)).pointer.child), push);
    for (mesh.surfaces.items) |surface| {
        const material = try self.render_resources.getMaterialPtr(surface.material_name);
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
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout.handle, 0, 1, &buf_idx_0, &off_0);
        const buf_idx_1: u32 = 1;
        const off_1: c.VkDeviceSize = 0;
        ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout.handle, 1, 1, &buf_idx_1, &off_1);

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

pub fn createStaticMesh(self: *@This(), gpa: std.mem.Allocator, name: []const u8, vertices: []const Mesh.StaticVertex, indices: []const u32, kind: shared.Entity.Kind) !void {
    if (self.render_resources.meshes.fetchSwapRemove(name)) |kv| {
        try check(c.vkDeviceWaitIdle(self.device.handle));
        var old_mesh = kv.value;
        old_mesh.deinit(self.gpa, self.vma);
        std.log.warn("swap removed excsisting mesh", .{});
    }
    const mesh = try StaticMesh.fromMesh(gpa, self.vma, self.device, &self.render_resources, name, vertices, indices, .{});
    if (self.renderables.get(kind)) |old| switch (old) {
        .static => |static| static.deinit(gpa),
        .skeletal => |skeletal| skeletal.deinit(gpa),
    };
    self.renderables.put(kind, .{ .static = mesh });
}

fn createShader(
    self: *@This(),
    name: []const u8,
    push_constant_type: type,
    stage_bit: c.VkShaderStageFlagBits,
    layouts_handles: []const c.VkDescriptorSetLayout,
) !*Shader {
    return Shader.init(
        self.gpa,
        self.device,
        self.asset_server,
        .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = stage_bit,
            .nextStage = if (stage_bit == c.VK_SHADER_STAGE_VERTEX_BIT) c.VK_SHADER_STAGE_FRAGMENT_BIT else 0,
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = "main",
        },
        layouts_handles,
        name,
        push_constant_type,
    );
}

pub fn attachSkeleton(self: *@This(), gpa: std.mem.Allocator, entity_id: u32, entity_kind: shared.Entity.Kind) !void {
    const renderable = self.renderables.get(entity_kind) orelse {
        if (entity_kind.expectsModel()) std.debug.panic("no model registered for {s}", .{@tagName(entity_kind)});
        return; // bullet/unknown: no skeleton
    };
    const model = switch (renderable) {
        .skeletal => |skeletal| skeletal,
        .static => return,
    };
    try self.skeletons.put(entity_id, try .init(gpa, self.vma, self.device, model));
}

pub fn removeSkeleton(self: *@This(), gpa: std.mem.Allocator, entity_id: u32) void {
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
