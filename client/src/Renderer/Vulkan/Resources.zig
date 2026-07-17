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
const Model = @import("Model.zig");
const Material = @import("Material.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("Shader.zig");
const Ui = @import("Ui.zig");
const Font = @import("Font.zig");
const FrameData = @import("FrameData.zig");
const AssetServer = @import("shared").AssetServer;

const check = @import("utils.zig").check;

pub const default_material_name: []const u8 = "default";
pub const default_mesh_name: []const u8 = "default";
const explosion_particle_material_name: []const u8 = "explosion_particle";
const explosion_particle_texture_size: u32 = 32;

pub const PipelineLayoutKind = enum { world, ui };

set_size: c.VkDeviceSize,
combined_image_sampler_descriptor_size: usize,
meshes: std.ArrayList(Mesh),
models: std.EnumArray(Model.Kind, Model),
shaders: std.EnumArray(Shader.Kind, Shader),
materials: std.ArrayList(Material),
skybox_material_index: usize,
samplers: std.ArrayList(c.VkSampler),
images: std.ArrayList(Image),
descriptor_layouts: std.EnumArray(DescriptorLayout.Kind, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayoutKind, PipelineLayout),
ui_texture_buffer: Buffer,
font: Font,
ui_image_indices: std.EnumArray(Ui.Texture, ?usize),
skybox: Image,
vma: Vma,
device: Device,

pub fn init(gpa: std.mem.Allocator, vma: Vma, physical_device: PhysicalDevice, device: Device, asset_server: *AssetServer) !*Resources {
    const meshes: std.ArrayList(Mesh) = .empty;
    var materials: std.ArrayList(Material) = .empty;
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
        .ui = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 64,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT),
    });

    const pipeline_layouts: std.EnumArray(PipelineLayoutKind, PipelineLayout) = .init(.{
        .world = try .init(device, Shader.AnimationPushConstant, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.material).handle,
        }),
        .ui = try .init(device, Shader.UiPushConstant, &.{
            descriptor_layouts.get(.ui).handle,
        }),
    });

    var set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, descriptor_layouts.get(.material).handle, &set_size);

    var ui_set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, descriptor_layouts.get(.ui).handle, &ui_set_size);

    const ui_texture_buffer: Buffer = try .init(
        device,
        vma,
        u8,
        ui_set_size * 64,
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

    const default_material: Material = try .init(
        gpa,
        default_material_name,
        device,
        vma,
        set_size,
        db_props.combinedImageSamplerDescriptorSize,
        default_sampler,
        default_texture.vk_imageview,
    );
    try materials.append(gpa, default_material);

    const self = try gpa.create(Resources);
    self.* = .{
        .combined_image_sampler_descriptor_size = db_props.combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .meshes = meshes,
        .models = .initFill(.empty),
        .shaders = undefined,
        .materials = materials,
        .samplers = samplers,
        .images = images,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .ui_texture_buffer = ui_texture_buffer,
        .font = try .init(gpa, vma, device, "fonts/Roboto-Regular.ttf"),
        .ui_image_indices = .initFill(null),
        .skybox = undefined,
        .skybox_material_index = undefined,
        .vma = vma,
        .device = device,
    };
    try asset_server.loadAndWatch(Resources, self, self.font.name, reloadFont);
    try self.loadUiTextures(gpa, vma, device);
    try self.loadSkybox(gpa);

    for (std.enums.values(Shader.Kind)) |kind| {
        const shader_spec = Shader.specs.get(kind);
        const layout_handles: []const c.VkDescriptorSetLayout = switch (shader_spec.layout) {
            .scene_material => &.{ descriptor_layouts.get(.scene).handle, descriptor_layouts.get(.material).handle },
            .ui => &.{descriptor_layouts.get(.ui).handle},
        };
        self.shaders.set(kind, .init(device, kind, layout_handles));
        try asset_server.loadAndWatch(Resources, self, shader_spec.path, reloadShader);
    }

    inline for (comptime std.enums.values(Ui.Texture)) |texture| {
        if (comptime texture.path()) |texture_path| {
            try asset_server.watch(Resources, self, texture_path["assets/".len..], reloadUiTexture);
        }
    }
    try asset_server.watch(Resources, self, "textures/skybox_cubemap.png", reloadSkybox);

    for (std.enums.values(Model.Kind)) |kind| {
        const path = kind.spec().path orelse continue;
        try asset_server.loadAndWatch(Resources, self, path, reloadModel);
    }

    return self;
}

fn reloadModel(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    const self: *Resources = @ptrCast(@alignCast(user_data));
    const kind = for (std.enums.values(Model.Kind)) |kind| {
        const spec_path = kind.spec().path orelse continue;
        if (std.mem.eql(u8, spec_path, file_path)) break kind;
    } else return error.UnknownModelPath;
    try self.models.getPtr(kind).loadGlb(gpa, io, file, self.vma, self.device, self, kind.spec());
}

fn reloadShader(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    const self: *Resources = @ptrCast(@alignCast(user_data));
    const kind = for (std.enums.values(Shader.Kind)) |kind| {
        if (std.mem.eql(u8, Shader.specs.get(kind).path, file_path)) break kind;
    } else return error.UnknownShaderPath;
    try self.shaders.getPtr(kind).load(gpa, io, file);
}

fn reloadFont(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;
    const self: *Resources = @ptrCast(@alignCast(user_data));
    try self.font.load(gpa, io, file);
}

pub fn createStaticMesh(self: *Resources, gpa: std.mem.Allocator, name: []const u8, vertices: []const Mesh.StaticVertex, indices: []const u32, model_kind: Model.Kind) !void {
    try self.createStaticMeshWithMaterial(gpa, name, vertices, indices, model_kind, null);
}

pub fn createExplosionParticleResources(self: *Resources, gpa: std.mem.Allocator) !void {
    var texture = try Image.init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{
            .width = explosion_particle_texture_size,
            .height = explosion_particle_texture_size,
            .depth = 1,
        },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer texture.deinit(self.vma, self.device);

    var pixels: [explosion_particle_texture_size * explosion_particle_texture_size * 4]u8 = undefined;
    fillExplosionParticleTexture(&pixels);
    try texture.uploadDataToImage(self.vma, self.device, &pixels, 4, 0);

    const material = try Material.init(
        gpa,
        explosion_particle_material_name,
        self.device,
        self.vma,
        self.set_size,
        self.combined_image_sampler_descriptor_size,
        self.samplers.items[0],
        texture.vk_imageview,
    );
    errdefer {
        var material_copy = material;
        material_copy.deinit(gpa, self.vma);
    }

    try self.images.append(gpa, texture);
    try self.materials.append(gpa, material);
    try self.createStaticMeshWithMaterial(
        gpa,
        "explosion_particle",
        Mesh.explosion_particle.verticies,
        Mesh.explosion_particle.indicies,
        .explosion_particle,
        self.materials.items.len - 1,
    );
}

fn fillExplosionParticleTexture(pixels: *[explosion_particle_texture_size * explosion_particle_texture_size * 4]u8) void {
    const size_f: f32 = @floatFromInt(explosion_particle_texture_size);
    const center = (size_f - 1.0) * 0.5;
    const radius = center;
    for (0..explosion_particle_texture_size) |y| {
        for (0..explosion_particle_texture_size) |x| {
            const x_f: f32 = @floatFromInt(x);
            const y_f: f32 = @floatFromInt(y);
            const dx = (x_f - center) / radius;
            const dy = (y_f - center) / radius;
            const distance = @sqrt(dx * dx + dy * dy);
            const core = std.math.clamp(1.0 - distance, 0.0, 1.0);
            const alpha = core * core;
            const heat = @sqrt(core);
            const pixel_index = (y * explosion_particle_texture_size + x) * 4;
            pixels[pixel_index + 0] = 255;
            pixels[pixel_index + 1] = @intFromFloat(70.0 + 165.0 * heat);
            pixels[pixel_index + 2] = @intFromFloat(12.0 + 36.0 * core);
            pixels[pixel_index + 3] = @intFromFloat(alpha * 255.0);
        }
    }
}

fn createStaticMeshWithMaterial(
    self: *Resources,
    gpa: std.mem.Allocator,
    name: []const u8,
    vertices: []const Mesh.StaticVertex,
    indices: []const u32,
    model_kind: Model.Kind,
    material_index: ?usize,
) !void {
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
            .material_index = material_index,
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

    const model = self.models.getPtr(model_kind);
    model.clear(gpa);
    try model.surfaces.append(gpa, .{ .mesh_id = mesh_id, .model_matrix = .identity });
    model.offset = .{};
}

fn reloadUiTexture(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    const self: *Resources = @ptrCast(@alignCast(user_data));
    inline for (comptime std.enums.values(Ui.Texture)) |texture| {
        if (comptime texture.path()) |texture_path| {
            if (std.mem.eql(u8, texture_path["assets/".len..], file_path)) {
                const image_index = self.ui_image_indices.get(texture) orelse return;
                const image = &self.images.items[image_index];

                var decoded = try decodeFile(gpa, io, file);
                defer decoded.deinit();

                //TODO: same-size reload only, resize needs new image + descriptor rewrite -> restart
                if (@as(u32, @intCast(decoded.width)) != image.extent.width or
                    @as(u32, @intCast(decoded.height)) != image.extent.height) return;
                try image.uploadDataToImage(self.vma, self.device, decoded.pixels, 4, 0);
                return;
            }
        }
    }
}

fn loadSkybox(self: *Resources, gpa: std.mem.Allocator) !void {
    var decoded: Image.Decoded = .{};
    defer decoded.deinit();
    var decode_tasks = [_]Image.DecodeTask{.{ .result = &decoded, .uri = "assets/textures/skybox_cubemap.png" }};
    try Image.decodeImages(gpa, &decode_tasks);
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;

    const face_size: u32 = @intCast(@divTrunc(decoded.width, 4));
    std.log.debug("res: {d}, face. {d}", .{ decoded.width, face_size });

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

    const sky_material: Material = try .init(
        gpa,
        "skybox",
        self.device,
        self.vma,
        self.set_size,
        self.combined_image_sampler_descriptor_size,
        self.samplers.items[0],
        self.skybox.vk_imageview,
    );
    try self.materials.append(gpa, sky_material);
    self.skybox_material_index = self.materials.items.len - 1;
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

        try self.skybox.uploadDataToImage(
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

fn reloadSkybox(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;
    const self: *Resources = @ptrCast(@alignCast(user_data));

    var decoded = try decodeFile(gpa, io, file);
    defer decoded.deinit();

    const face_size: u32 = @intCast(@divTrunc(decoded.width, 4));
    if (face_size != self.skybox.extent.width) return;
    try self.uploadSkyboxFaces(gpa, decoded);
}

fn loadUiTextures(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) !void {
    const loadable_textures = comptime blk: {
        var textures: []const Ui.Texture = &.{};
        for (std.enums.values(Ui.Texture)) |texture| {
            if (texture.path() != null) textures = textures ++ .{texture};
        }
        break :blk textures;
    };

    var decoded_ui_images: [loadable_textures.len]Image.Decoded = @splat(.{});
    defer for (&decoded_ui_images) |*decoded_ui_image| decoded_ui_image.deinit();

    var ui_decode_tasks: [loadable_textures.len]Image.DecodeTask = undefined;
    inline for (loadable_textures, 0..) |texture, task_index| {
        ui_decode_tasks[task_index] = .{ .result = &decoded_ui_images[task_index], .uri = texture.path().? };
    }
    try Image.decodeImages(gpa, &ui_decode_tasks);

    var ui_views: std.EnumArray(Ui.Texture, c.VkImageView) = .initFill(self.images.items[0].vk_imageview);
    ui_views.set(.font_atlas, self.font.image.vk_imageview);
    inline for (loadable_textures, 0..) |texture, task_index| {
        const decoded_ui_image = decoded_ui_images[task_index];
        var ui_image: Image = try .init(
            vma,
            device,
            c.VK_FORMAT_R8G8B8A8_UNORM,
            .{
                .width = @intCast(decoded_ui_image.width),
                .height = @intCast(decoded_ui_image.height),
                .depth = 1,
            },
            .@"2d",
            c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            c.VK_IMAGE_ASPECT_COLOR_BIT,
            false,
        );
        try ui_image.uploadDataToImage(vma, device, decoded_ui_image.pixels, 4, 0);
        try self.images.append(gpa, ui_image);
        self.ui_image_indices.set(texture, self.images.items.len - 1);
        ui_views.set(texture, ui_image.vk_imageview);
    }

    var binding_offset: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutBindingOffsetEXT(device.handle, self.descriptor_layouts.get(.ui).handle, 0, &binding_offset);

    for (0..64) |slot_index| {
        const texture: Ui.Texture = if (slot_index < std.enums.values(Ui.Texture).len) @enumFromInt(slot_index) else .blank;
        const sampler = if (texture == .font_atlas) self.font.sampler else self.samplers.items[0];

        const image_info: c.VkDescriptorImageInfo = .{
            .sampler = sampler,
            .imageView = ui_views.get(texture),
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const descriptor_get_info: c.VkDescriptorGetInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .data = .{ .pCombinedImageSampler = &image_info },
        };
        const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.ui_texture_buffer.info.pMappedData);
        ext.vkGetDescriptorEXT(
            device.handle,
            &descriptor_get_info,
            self.combined_image_sampler_descriptor_size,
            descriptor_buffer_bytes + binding_offset + slot_index * self.combined_image_sampler_descriptor_size,
        );
    }
}

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    for (self.materials.items) |*material| {
        material.deinit(gpa, vma);
    }
    self.materials.deinit(gpa);

    for (self.images.items) |*image| {
        image.deinit(vma, device);
    }
    self.images.deinit(gpa);
    self.skybox.deinit(vma, device);

    for (self.samplers.items) |sampler| {
        c.vkDestroySampler(device.handle, sampler, null);
    }
    self.samplers.deinit(gpa);

    for (self.meshes.items) |*mesh| {
        mesh.deinit(gpa, vma);
    }
    self.meshes.deinit(gpa);
    for (&self.models.values) |*model| model.deinit(gpa);
    for (&self.shaders.values) |*shader| shader.deinit();

    for (self.descriptor_layouts.values) |layout| {
        layout.deinit(device);
    }
    for (&self.pipeline_layouts.values) |*layout| {
        layout.deinit(device);
    }
    self.ui_texture_buffer.deinit(vma);
    self.font.deinit(gpa, vma, device);
    gpa.destroy(self);
}

pub fn getMeshPtr(self: *Resources, index: usize) *Mesh {
    return &self.meshes.items[index];
}
pub fn getMaterialPtr(self: *Resources, index: ?usize) *Material {
    return &self.materials.items[index orelse 0];
}
