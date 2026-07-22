const Resources = @This();

const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const DescriptorLayout = @import("DesrciptorLayout.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const Mesh = @import("Mesh.zig");
const Model = @import("../../asset/Model.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("Shader.zig");
const Font = @import("Font.zig");
const FrameData = @import("FrameData.zig");
const AssetServer = @import("shared").AssetServer;
const entity = @import("shared").entity;
const gltf = @import("../../asset/gltf.zig");

const check = @import("utils.zig").check;

pub const default_mesh_name: []const u8 = "default";
pub const explosion_particle_name: []const u8 = "explosion_particle";
pub const lightning_particle_name: []const u8 = "lightning_particle";
pub const max_textures = 256;
const particle_texture_size: u32 = 64;

pub const PipelineLayoutKind = enum { world, sky, ui };

const skybox_texture_key = "textures/skybox_cubemap.png";
pub const crosshair_texture_key = "textures/crosshair.png";
const font_files = [_][]const u8{"Roboto-Regular.ttf"};

const shader_files = blk: {
    var files: [Shader.all_kinds.len][]const u8 = undefined;
    for (Shader.all_kinds, 0..) |kind, i| files[i] = Shader.spec(kind).path["shaders/".len..];
    break :blk files;
};

const model_file_keys = blk: {
    var keys: []const []const u8 = &.{};
    for (entity.all_kinds) |kind| {
        const key = entity.modelSpec(kind).key;
        if (!std.mem.endsWith(u8, key, ".glb")) continue;
        for (keys) |existing| {
            if (std.mem.eql(u8, existing, key)) break;
        } else keys = keys ++ .{key};
    }
    break :blk keys;
};
const model_files = blk: {
    var files: [model_file_keys.len][]const u8 = undefined;
    for (model_file_keys, 0..) |key, i| files[i] = key["objects/".len..];
    break :blk files;
};

const texture_file_keys = blk: {
    var keys: []const []const u8 = &.{ skybox_texture_key, crosshair_texture_key };
    for (entity.all_kinds) |kind| {
        const icon = entity.spec(kind).icon orelse continue;
        for (keys) |existing| {
            if (std.mem.eql(u8, existing, icon)) break;
        } else keys = keys ++ .{icon};
    }
    break :blk keys;
};
const texture_files = blk: {
    var files: [texture_file_keys.len][]const u8 = undefined;
    for (texture_file_keys, 0..) |key, i| {
        std.debug.assert(std.mem.startsWith(u8, key, "textures/"));
        files[i] = key["textures/".len..];
    }
    break :blk files;
};

pub const shadow_cascade_count = 3;
pub const shadow_map_size: u32 = 2048;

pub const GPUCascades = extern struct {
    light_view_proj: [shadow_cascade_count][16]f32,
    splits: [4]f32,
};

set_size: c.VkDeviceSize,
combined_image_sampler_descriptor_size: usize,
meshes: std.ArrayList(Mesh),
models: std.ArrayList(Model),
model_keys: std.StringHashMapUnmanaged(Model.Handle),
shaders: [Shader.all_kinds.len]Shader,
skybox_descriptor: Buffer,
samplers: std.ArrayList(c.VkSampler),
images: std.ArrayList(Image),
descriptor_layouts: std.EnumArray(DescriptorLayout.Kind, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayoutKind, PipelineLayout),
texture_descriptor_buffer: Buffer,
texture_binding_offset: c.VkDeviceSize,
texture_keys: std.StringHashMapUnmanaged(Image.Handle),
identity_joint_buffer: Buffer,
shadow_image: Image,
shadow_sampler: c.VkSampler,
shadow_descriptor_buffers: [FrameData.max_frames_inflight]Buffer,
shadow_cascade_offset: c.VkDeviceSize,
font: Font,
skybox: ?Image,
font_loader: AssetServer.Loader,
shader_loader: AssetServer.Loader,
model_loader: AssetServer.Loader,
texture_loader: AssetServer.Loader,
vma: Vma,
device: Device,

pub fn init(gpa: std.mem.Allocator, vma: Vma, physical_device: PhysicalDevice, device: Device, asset_server: *AssetServer) !*Resources {
    const meshes: std.ArrayList(Mesh) = .empty;
    var samplers: std.ArrayList(c.VkSampler) = .empty;
    var images: std.ArrayList(Image) = .empty;

    var db_props: c.VkPhysicalDeviceDescriptorBufferPropertiesEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    };
    var prop2: c.VkPhysicalDeviceProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &db_props,
    };
    c.vkGetPhysicalDeviceProperties2(physical_device.handle, &prop2);

    const descriptor_layouts: std.EnumArray(DescriptorLayout.Kind, DescriptorLayout) = .init(.{
        .scene = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = @sizeOf(FrameData.GPUScene),
                .descriptorType = c.VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT),
        .material = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT),
        .shadow = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = 1,
                .descriptorCount = @sizeOf(GPUCascades),
                .descriptorType = c.VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK,
                .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT),
        .textures = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = max_textures,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT),
    });

    const pipeline_layouts: std.EnumArray(PipelineLayoutKind, PipelineLayout) = .init(.{
        .world = try .init(device, Shader.WorldPushConstant, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.textures).handle,
            descriptor_layouts.get(.shadow).handle,
        }),
        .sky = try .init(device, Shader.WorldPushConstant, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.material).handle,
        }),
        .ui = try .init(device, Shader.UiPushConstant, &.{
            descriptor_layouts.get(.textures).handle,
        }),
    });

    var set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, descriptor_layouts.get(.material).handle, &set_size);

    var ui_set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, descriptor_layouts.get(.textures).handle, &ui_set_size);

    var texture_binding_offset: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutBindingOffsetEXT(device.handle, descriptor_layouts.get(.textures).handle, 0, &texture_binding_offset);

    const texture_descriptor_buffer: Buffer = try .init(
        device,
        vma,
        u8,
        ui_set_size,
        c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
            c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
    );

    var default_texture: Image = try .init(
        vma,
        device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 1, .height = 1, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var green_color: nz.color.Rgba(u8) = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    try default_texture.uploadDataToImage(vma, device, &green_color, 4, 0);
    try images.append(gpa, default_texture);
    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .anisotropyEnable = c.VK_FALSE,
        .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
        .compareEnable = c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_ALWAYS,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
    };
    var default_sampler: c.VkSampler = undefined;
    try check(c.vkCreateSampler(device.handle, &sampler_info, null, &default_sampler));
    try samplers.append(gpa, default_sampler);

    var identity_joint_buffer: Buffer = try .init(
        device,
        vma,
        nz.Mat4x4(f32),
        1,
        c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
    );
    identity_joint_buffer.copy(nz.Mat4x4(f32), &.{.identity});

    const shadow_image: Image = try .init(
        vma,
        device,
        c.VK_FORMAT_D32_SFLOAT,
        .{ .width = shadow_map_size * shadow_cascade_count, .height = shadow_map_size, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_DEPTH_BIT,
        false,
    );
    const shadow_sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .compareEnable = c.VK_TRUE,
        .compareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
    };
    var shadow_sampler: c.VkSampler = undefined;
    try check(c.vkCreateSampler(device.handle, &shadow_sampler_info, null, &shadow_sampler));

    var shadow_set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, descriptor_layouts.get(.shadow).handle, &shadow_set_size);
    var shadow_sampler_offset: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutBindingOffsetEXT(device.handle, descriptor_layouts.get(.shadow).handle, 0, &shadow_sampler_offset);
    var shadow_cascade_offset: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutBindingOffsetEXT(device.handle, descriptor_layouts.get(.shadow).handle, 1, &shadow_cascade_offset);

    var shadow_descriptor_buffers: [FrameData.max_frames_inflight]Buffer = undefined;
    for (&shadow_descriptor_buffers) |*shadow_descriptor_buffer| {
        shadow_descriptor_buffer.* = try .init(
            device,
            vma,
            u8,
            shadow_set_size,
            c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
        );
        const shadow_image_info: c.VkDescriptorImageInfo = .{
            .sampler = shadow_sampler,
            .imageView = shadow_image.vk_imageview,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const shadow_descriptor_get_info: c.VkDescriptorGetInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .data = .{ .pCombinedImageSampler = &shadow_image_info },
        };
        const shadow_descriptor_bytes: [*]u8 = @ptrCast(shadow_descriptor_buffer.info.pMappedData);
        ext.vkGetDescriptorEXT(
            device.handle,
            &shadow_descriptor_get_info,
            db_props.combinedImageSamplerDescriptorSize,
            shadow_descriptor_bytes + shadow_sampler_offset,
        );
    }

    const self = try gpa.create(Resources);
    self.* = .{
        .combined_image_sampler_descriptor_size = db_props.combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .meshes = meshes,
        .models = .empty,
        .model_keys = .empty,
        .shaders = undefined,
        .samplers = samplers,
        .images = images,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .texture_descriptor_buffer = texture_descriptor_buffer,
        .texture_binding_offset = texture_binding_offset,
        .texture_keys = .empty,
        .identity_joint_buffer = identity_joint_buffer,
        .shadow_image = shadow_image,
        .shadow_sampler = shadow_sampler,
        .shadow_descriptor_buffers = shadow_descriptor_buffers,
        .shadow_cascade_offset = shadow_cascade_offset,
        .font = .init(vma, device),
        .skybox = null,
        .skybox_descriptor = try .init(
            device,
            vma,
            u8,
            set_size,
            c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
        ),
        .font_loader = .{ .root_path = "fonts", .files = &font_files, .load = fontLoaderLoad },
        .shader_loader = .{ .root_path = "shaders", .files = &shader_files, .load = shaderLoaderLoad },
        .model_loader = .{ .root_path = "objects", .files = &model_files, .load = modelLoaderLoad },
        .texture_loader = .{ .root_path = "textures", .files = &texture_files, .load = textureLoaderLoad },
        .vma = vma,
        .device = device,
    };
    for (0..max_textures) |slot| self.writeTextureDescriptor(slot, default_texture.vk_imageview, default_sampler);
    try asset_server.addLoader(&self.font_loader);
    try asset_server.addLoader(&self.shader_loader);
    try asset_server.addLoader(&self.model_loader);
    try asset_server.addLoader(&self.texture_loader);

    for (Shader.all_kinds) |kind| {
        const shader_spec = Shader.spec(kind);
        const layout_handles: []const c.VkDescriptorSetLayout = switch (shader_spec.layout) {
            .scene_textures => &.{ descriptor_layouts.get(.scene).handle, descriptor_layouts.get(.textures).handle, descriptor_layouts.get(.shadow).handle },
            .sky => &.{ descriptor_layouts.get(.scene).handle, descriptor_layouts.get(.material).handle },
            .ui => &.{descriptor_layouts.get(.textures).handle},
        };
        self.shaders[Shader.index(kind)] = .init(device, kind, layout_handles);
    }

    const default_model = try self.createStaticMesh(gpa, default_mesh_name, Mesh.box.verticies, Mesh.box.indicies);
    std.debug.assert(default_model == Model.Handle.default);
    _ = try self.createStaticMesh(gpa, "cube_projectile", Mesh.box.verticies, Mesh.box.indicies);
    try self.createParticleResources(gpa, explosion_particle_name, .{
        .edge_color = .{ 255, 70, 12 },
        .center_color = .{ 255, 235, 48 },
    });
    try self.createParticleResources(gpa, lightning_particle_name, .{
        .edge_color = .{ 110, 160, 255 },
        .center_color = .{ 255, 255, 255 },
    });
    try self.registerEntityModels(gpa);

    return self;
}

fn modelLoaderLoad(loader: *AssetServer.Loader, gpa: std.mem.Allocator, io: std.Io, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *Resources = @fieldParentPtr("model_loader", loader);
    const file = try err_file;
    const key = model_file_keys[index];
    const spec = for (entity.all_kinds) |kind| {
        const model_spec = entity.modelSpec(kind);
        if (std.mem.eql(u8, model_spec.key, key)) break model_spec;
    } else return error.UnknownModelPath;
    const handle = self.model_keys.get(key) orelse return error.UnknownModelPath;
    const model = &self.models.items[handle.index()];
    if (spec.skinned) {
        var upload_data = try model.parseGlb(Mesh.SkinnedVertex, gpa, io, file, spec);
        defer upload_data.deinit(gpa);
        const base_mesh_index = try self.uploadModel(gpa, Mesh.SkinnedVertex, upload_data, spec.key);
        try model.finalize(gpa, base_mesh_index, spec);
    } else {
        var upload_data = try model.parseGlb(Mesh.StaticVertex, gpa, io, file, spec);
        defer upload_data.deinit(gpa);
        const base_mesh_index = try self.uploadModel(gpa, Mesh.StaticVertex, upload_data, spec.key);
        try model.finalize(gpa, base_mesh_index, spec);
    }
}

fn shaderLoaderLoad(loader: *AssetServer.Loader, gpa: std.mem.Allocator, io: std.Io, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *Resources = @fieldParentPtr("shader_loader", loader);
    const file = err_file catch |err| std.debug.panic(
        "shader missing: assets/shaders/{s} ({t}) -- check the path in Shader.specs",
        .{ shader_files[index], err },
    );
    try self.shaders[index].load(gpa, io, file);
}

fn fontLoaderLoad(loader: *AssetServer.Loader, gpa: std.mem.Allocator, io: std.Io, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    _ = index;
    const self: *Resources = @fieldParentPtr("font_loader", loader);
    const file = try err_file;
    const old_sampler = self.font.sampler;
    const atlas_image = try self.font.load(gpa, io, file);
    self.font.atlas_texture = try self.registerImage(gpa, "font_atlas", atlas_image, self.font.sampler);
    if (old_sampler != null) c.vkDestroySampler(self.device.handle, old_sampler, null);
}

fn textureLoaderLoad(loader: *AssetServer.Loader, gpa: std.mem.Allocator, io: std.Io, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *Resources = @fieldParentPtr("texture_loader", loader);
    const file = try err_file;
    const key = texture_file_keys[index];
    if (std.mem.eql(u8, key, skybox_texture_key)) return self.skyboxFromFile(gpa, io, file);

    var decoded = try decodeFile(gpa, io, file);
    defer decoded.deinit();

    var image: Image = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = @intCast(decoded.width), .height = @intCast(decoded.height), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer image.deinit(self.vma, self.device);
    try image.uploadDataToImage(self.vma, self.device, decoded.pixels, 4, 0);
    _ = try self.registerImage(gpa, key, image, self.samplers.items[0]);
}

pub fn uploadModel(self: *Resources, gpa: std.mem.Allocator, comptime VertexType: type, upload: gltf.UploadData(VertexType), key_prefix: []const u8) !usize {
    const base_sampler_index = self.samplers.items.len;
    for (upload.samplers) |desc| {
        const sampler_info: c.VkSamplerCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .maxLod = c.VK_LOD_CLAMP_NONE,
            .minLod = 0,
            .magFilter = if (desc.mag_linear) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST,
            .minFilter = if (desc.min_linear) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .anisotropyEnable = c.VK_FALSE,
            .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = c.VK_FALSE,
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
        };
        var new_sampler: c.VkSampler = undefined;
        try check(c.vkCreateSampler(self.device.handle, &sampler_info, null, &new_sampler));
        try self.samplers.append(gpa, new_sampler);
    }

    const image_handles = try gpa.alloc(Image.Handle, upload.images.len);
    defer gpa.free(image_handles);
    if (upload.images.len > 0) {
        var upload_buffers: std.ArrayList(Buffer) = .empty;
        defer {
            for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(self.vma);
            upload_buffers.deinit(gpa);
        }
        const upload_cmd = try self.device.beginImmediateCommand();
        for (upload.images, upload.image_sampler, 0..) |decoded_image, sampler_index, image_index| {
            var new_image: Image = try .init(
                self.vma,
                self.device,
                c.VK_FORMAT_R8G8B8A8_UNORM,
                .{ .width = @intCast(decoded_image.width), .height = @intCast(decoded_image.height), .depth = 1 },
                .@"2d",
                c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                c.VK_IMAGE_ASPECT_COLOR_BIT,
                true,
            );
            try new_image.recordUploadDataToImage(
                gpa,
                self.vma,
                self.device,
                upload_cmd,
                decoded_image.pixels,
                0,
                4,
                &upload_buffers,
            );
            var key_buffer: [512]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "{s}#{d}", .{ key_prefix, image_index });
            image_handles[image_index] = try self.registerImage(gpa, key, new_image, self.samplers.items[0]);
            if (sampler_index) |gltf_sampler_index|
                self.setTextureSampler(image_handles[image_index], self.samplers.items[base_sampler_index + gltf_sampler_index]);
        }
        try self.device.endImmediateCommand(upload_cmd);
    }

    const base_mesh_index = self.meshes.items.len;
    for (upload.meshes) |mesh_data| {
        const surfaces = try gpa.alloc(Mesh.GeoSurface, mesh_data.surfaces.len);
        defer gpa.free(surfaces);
        for (mesh_data.surfaces, surfaces) |surface_data, *surface| surface.* = .{
            .index_start = surface_data.index_start,
            .index_count = surface_data.index_count,
            .texture = if (surface_data.image_index) |image_index| image_handles[image_index] else .blank,
        };
        const new_mesh: Mesh = try .init(
            gpa,
            self.vma,
            mesh_data.name,
            self.device,
            VertexType,
            mesh_data.vertices,
            mesh_data.indices,
            surfaces,
        );
        try self.meshes.append(gpa, new_mesh);
    }
    return base_mesh_index;
}

pub fn registerModel(self: *Resources, gpa: std.mem.Allocator, key: []const u8) !Model.Handle {
    if (self.model_keys.get(key)) |handle| return handle;
    try self.models.append(gpa, .empty);
    const handle: Model.Handle = @enumFromInt(self.models.items.len - 1);
    try self.model_keys.put(gpa, key, handle);
    return handle;
}

pub fn registerEntityModels(self: *Resources, gpa: std.mem.Allocator) !void {
    for (entity.all_kinds) |kind| {
        _ = try self.registerModel(gpa, entity.modelSpec(kind).key);
    }
}

pub fn shaderPtr(self: *Resources, kind: Shader.Kind) *Shader {
    return &self.shaders[Shader.index(kind)];
}

pub fn textureHandle(self: *Resources, key: []const u8) Image.Handle {
    return self.texture_keys.get(key).?;
}

pub fn modelHandle(self: *Resources, key: []const u8) Model.Handle {
    return self.model_keys.get(key).?;
}

pub fn modelForKind(self: *Resources, kind: entity.Kind) *Model {
    return self.getModelPtr(self.model_keys.get(entity.modelSpec(kind).key).?);
}

fn writeTextureDescriptor(self: *Resources, slot: usize, view: c.VkImageView, sampler: c.VkSampler) void {
    const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.texture_descriptor_buffer.info.pMappedData);
    self.writeCombinedSamplerDescriptor(descriptor_buffer_bytes + self.texture_binding_offset + slot * self.combined_image_sampler_descriptor_size, view, sampler);
}

fn writeCombinedSamplerDescriptor(self: *Resources, destination: [*]u8, view: c.VkImageView, sampler: c.VkSampler) void {
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = sampler,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const descriptor_get_info: c.VkDescriptorGetInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .data = .{ .pCombinedImageSampler = &image_info },
    };
    ext.vkGetDescriptorEXT(
        self.device.handle,
        &descriptor_get_info,
        self.combined_image_sampler_descriptor_size,
        destination,
    );
}

pub fn registerImage(self: *Resources, gpa: std.mem.Allocator, key: ?[]const u8, image: Image, sampler: c.VkSampler) !Image.Handle {
    if (key) |existing_key| if (self.texture_keys.get(existing_key)) |handle| {
        const slot = handle.index();
        try check(c.vkDeviceWaitIdle(self.device.handle));
        self.images.items[slot].deinit(self.vma, self.device);
        self.images.items[slot] = image;
        self.writeTextureDescriptor(slot, image.vk_imageview, sampler);
        return handle;
    };
    std.debug.assert(self.images.items.len < max_textures);
    try self.images.append(gpa, image);
    const slot = self.images.items.len - 1;
    self.writeTextureDescriptor(slot, image.vk_imageview, sampler);
    if (key) |new_key| try self.texture_keys.put(gpa, try gpa.dupe(u8, new_key), @enumFromInt(slot));
    std.log.debug("texture {d}/{d}: {s}", .{ slot + 1, max_textures, key orelse "unnamed" });
    return @enumFromInt(slot);
}

pub fn setTextureSampler(self: *Resources, handle: Image.Handle, sampler: c.VkSampler) void {
    const slot = handle.index();
    self.writeTextureDescriptor(slot, self.images.items[slot].vk_imageview, sampler);
}

pub fn createStaticMesh(self: *Resources, gpa: std.mem.Allocator, name: []const u8, vertices: []const Mesh.StaticVertex, indices: []const u32) !Model.Handle {
    return self.createStaticMeshWithTexture(gpa, name, vertices, indices, .blank);
}

pub const ParticleColorRamp = struct {
    edge_color: [3]f32,
    center_color: [3]f32,
};

pub fn createParticleResources(
    self: *Resources,
    gpa: std.mem.Allocator,
    name: []const u8,
    ramp: ParticleColorRamp,
) !void {
    var texture = try Image.init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{
            .width = particle_texture_size,
            .height = particle_texture_size,
            .depth = 1,
        },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer texture.deinit(self.vma, self.device);

    var pixels: [particle_texture_size * particle_texture_size * 4]u8 = undefined;
    const size_f: f32 = @floatFromInt(particle_texture_size);
    const center = (size_f - 1.0) * 0.5;
    const radius = center;
    for (0..particle_texture_size) |y| {
        for (0..particle_texture_size) |x| {
            const x_f: f32 = @floatFromInt(x);
            const y_f: f32 = @floatFromInt(y);
            const dx = (x_f - center) / radius;
            const dy = (y_f - center) / radius;
            const distance = @sqrt(dx * dx + dy * dy);
            const core = std.math.clamp(1.0 - distance, 0.0, 1.0);
            const alpha = core * core;
            const heat = @sqrt(core);
            const pixel_index = (y * particle_texture_size + x) * 4;
            for (0..3) |channel| {
                pixels[pixel_index + channel] = @intFromFloat(ramp.edge_color[channel] + (ramp.center_color[channel] - ramp.edge_color[channel]) * heat);
            }
            pixels[pixel_index + 3] = @intFromFloat(alpha * 255.0);
        }
    }
    try texture.uploadDataToImage(self.vma, self.device, &pixels, 4, 0);

    _ = try self.registerImage(gpa, name, texture, self.samplers.items[0]);
}

fn createStaticMeshWithTexture(
    self: *Resources,
    gpa: std.mem.Allocator,
    name: []const u8,
    vertices: []const Mesh.StaticVertex,
    indices: []const u32,
    texture: Image.Handle,
) !Model.Handle {
    const existing_index = for (self.meshes.items, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.name, name)) break index;
    } else null;
    if (existing_index != null) try check(c.vkDeviceWaitIdle(self.device.handle));

    const mesh = try Mesh.init(
        gpa,
        self.vma,
        name,
        self.device,
        Mesh.StaticVertex,
        vertices,
        indices,
        &.{.{
            .index_start = 0,
            .index_count = @intCast(indices.len),
            .texture = texture,
        }},
    );
    const mesh_id = if (existing_index) |index| blk: {
        self.meshes.items[index].deinit(gpa, self.vma);
        self.meshes.items[index] = mesh;
        break :blk index;
    } else blk: {
        try self.meshes.append(gpa, mesh);
        break :blk self.meshes.items.len - 1;
    };

    const handle = try self.registerModel(gpa, name);
    const model = &self.models.items[handle.index()];
    model.clear(gpa);
    try model.surfaces.append(gpa, .{ .mesh_id = mesh_id, .model_matrix = .identity });
    return handle;
}

fn skyboxFromFile(self: *Resources, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !void {
    var decoded = try decodeFile(gpa, io, file);
    defer decoded.deinit();

    const face_size: u32 = @intCast(@divTrunc(decoded.width, 4));
    if (self.skybox != null) {
        //TODO: same-size reload only, resize needs a new image + descriptor rewrite -> restart
        if (face_size != self.skybox.?.extent.width) return;
        try self.uploadSkyboxFaces(gpa, decoded);
        return;
    }

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
    try self.uploadSkyboxFaces(gpa, decoded);

    self.writeCombinedSamplerDescriptor(@ptrCast(self.skybox_descriptor.info.pMappedData), self.skybox.?.vk_imageview, self.samplers.items[0]);
}

fn uploadSkyboxFaces(self: *Resources, gpa: std.mem.Allocator, decoded: Image.Decoded) !void {
    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);
    const channels: u32 = @intCast(decoded.nr_channel);
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
            @memcpy(data[dst..][0..row_bytes], decoded.pixels[src..][0..row_bytes]);
        }

        try self.skybox.?.uploadDataToImage(
            self.vma,
            self.device,
            data,
            channels,
            @intCast(i),
        );
    }
}

fn decodeFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !Image.Decoded {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);

    var decoded: Image.Decoded = .{};
    var decode_tasks = [_]Image.DecodeTask{.{ .result = &decoded, .bytes = bytes }};
    try Image.decodeImages(gpa, &decode_tasks);
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;
    return decoded;
}

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    for (self.images.items) |*image| {
        image.deinit(vma, device);
    }
    self.images.deinit(gpa);
    if (self.skybox != null) self.skybox.?.deinit(vma, device);
    self.skybox_descriptor.deinit(vma);

    for (self.samplers.items) |sampler| {
        c.vkDestroySampler(device.handle, sampler, null);
    }
    self.samplers.deinit(gpa);

    for (self.meshes.items) |*mesh| {
        mesh.deinit(gpa, vma);
    }
    self.meshes.deinit(gpa);
    for (self.models.items) |*model| model.deinit(gpa);
    self.models.deinit(gpa);
    self.model_keys.deinit(gpa);
    for (&self.shaders) |*shader| shader.deinit();

    for (self.descriptor_layouts.values) |layout| {
        layout.deinit(device);
    }
    for (&self.pipeline_layouts.values) |*layout| {
        layout.deinit(device);
    }
    self.texture_descriptor_buffer.deinit(vma);
    self.identity_joint_buffer.deinit(vma);
    self.shadow_image.deinit(vma, device);
    c.vkDestroySampler(device.handle, self.shadow_sampler, null);
    for (&self.shadow_descriptor_buffers) |*shadow_descriptor_buffer| shadow_descriptor_buffer.deinit(vma);
    var key_iterator = self.texture_keys.keyIterator();
    while (key_iterator.next()) |texture_key| gpa.free(texture_key.*);
    self.texture_keys.deinit(gpa);
    self.font.deinit(device);
    gpa.destroy(self);
}

pub fn writeCascades(self: *Resources, frame_index: usize, cascades: *const GPUCascades) void {
    const bytes: [*]u8 = @ptrCast(self.shadow_descriptor_buffers[frame_index].info.pMappedData);
    @memcpy(
        bytes[self.shadow_cascade_offset..][0..@sizeOf(GPUCascades)],
        @as([*]const u8, @ptrCast(cascades))[0..@sizeOf(GPUCascades)],
    );
}

pub fn getMeshPtr(self: *Resources, index: usize) *Mesh {
    return &self.meshes.items[index];
}
pub fn getModelPtr(self: *Resources, handle: Model.Handle) *Model {
    return &self.models.items[handle.index()];
}
