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
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("Shader.zig");
const Font = @import("Font.zig");
const FrameData = @import("FrameData.zig");
const AssetServer = @import("shared").AssetServer;

const check = @import("utils.zig").check;

pub const default_mesh_name: []const u8 = "default";
pub const max_textures = 256;
const explosion_particle_texture_size: u32 = 32;

pub const PipelineLayoutKind = enum { world, sky, ui };

set_size: c.VkDeviceSize,
combined_image_sampler_descriptor_size: usize,
meshes: std.ArrayList(Mesh),
models: std.EnumArray(Model.Kind, Model),
shaders: std.EnumArray(Shader.Kind, Shader),
// TEMP-COMMENT: materials list deleted — a "material" was one descriptor buffer around one
// texture; surfaces now carry Image.Handle directly. Skybox keeps ONE private descriptor
// buffer (cube sampler can't live in the sampler2D array; typed cube array = later upgrade).
skybox_descriptor: Buffer,
samplers: std.ArrayList(c.VkSampler),
images: std.ArrayList(Image),
descriptor_layouts: std.EnumArray(DescriptorLayout.Kind, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayoutKind, PipelineLayout),
texture_descriptor_buffer: Buffer,
texture_binding_offset: c.VkDeviceSize,
texture_keys: std.StringHashMapUnmanaged(Image.Handle),
identity_joint_buffer: Buffer,
font: Font,
skybox: Image,
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

    const self = try gpa.create(Resources);
    self.* = .{
        .combined_image_sampler_descriptor_size = db_props.combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .meshes = meshes,
        .models = .initFill(.empty),
        .shaders = undefined,
        .samplers = samplers,
        .images = images,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .texture_descriptor_buffer = texture_descriptor_buffer,
        .texture_binding_offset = texture_binding_offset,
        .texture_keys = .empty,
        .identity_joint_buffer = identity_joint_buffer,
        .font = try .init(gpa, vma, device, "fonts/Roboto-Regular.ttf"),
        .skybox = undefined,
        .skybox_descriptor = undefined,
        .vma = vma,
        .device = device,
    };
    for (0..max_textures) |slot| self.writeTextureDescriptor(@intCast(slot), default_texture.vk_imageview, default_sampler);
    try asset_server.loadAndWatch(Resources, self, self.font.name, reloadFont);
    try self.loadSkybox(gpa);

    for (std.enums.values(Shader.Kind)) |kind| {
        const shader_spec = Shader.specs.get(kind);
        const layout_handles: []const c.VkDescriptorSetLayout = switch (shader_spec.layout) {
            .scene_textures => &.{ descriptor_layouts.get(.scene).handle, descriptor_layouts.get(.textures).handle },
            .sky => &.{ descriptor_layouts.get(.scene).handle, descriptor_layouts.get(.material).handle },
            .ui => &.{descriptor_layouts.get(.textures).handle},
        };
        self.shaders.set(kind, .init(device, kind, layout_handles));
        try asset_server.loadAndWatch(Resources, self, shader_spec.path, reloadShader);
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
    // TEMP-COMMENT: font.load creates a NEW image+sampler each call; before this change the old
    // ones leaked on every hot reload. registerImage destroys the old image (same key = same
    // slot override), the old sampler we destroy here ourselves since the pool doesn't own samplers.
    const old_sampler = self.font.sampler;
    try self.font.load(gpa, io, file);
    // TEMP-COMMENT: atlas joins the pool like any texture, keyed "font_atlas" so reloads
    // overwrite the same slot; Ui reads default_font.atlas_texture instead of enum slot 1.
    self.font.atlas_texture = try self.registerImage(gpa, "font_atlas", self.font.image, self.font.sampler);
    if (old_sampler != null) c.vkDestroySampler(self.device.handle, old_sampler, null);
}

// TEMP-COMMENT: the ONE place a descriptor slot gets written. slot == index into images ==
// @intFromEnum(Image.Handle) — no mapping tables anywhere.
fn writeTextureDescriptor(self: *Resources, slot: u32, view: c.VkImageView, sampler: c.VkSampler) void {
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
    const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.texture_descriptor_buffer.info.pMappedData);
    ext.vkGetDescriptorEXT(
        self.device.handle,
        &descriptor_get_info,
        self.combined_image_sampler_descriptor_size,
        descriptor_buffer_bytes + self.texture_binding_offset + slot * self.combined_image_sampler_descriptor_size,
    );
}

// TEMP-COMMENT: the ONE door into the texture pool. key=null → anonymous append (generated
// textures). Known key → OVERRIDE: destroy old image, reuse the same slot, rewrite descriptor —
// every holder of the handle sees the new texture for free. This is what makes hot reload
// (including GLTF re-loads later) stop growing the pool.
pub fn registerImage(self: *Resources, gpa: std.mem.Allocator, key: ?[]const u8, image: Image, sampler: c.VkSampler) !Image.Handle {
    if (key) |existing_key| if (self.texture_keys.get(existing_key)) |handle| {
        const slot = @intFromEnum(handle);
        // TEMP-COMMENT: GPU may still be sampling the old image this frame → wait before destroy.
        try check(c.vkDeviceWaitIdle(self.device.handle));
        self.images.items[slot].deinit(self.vma, self.device);
        self.images.items[slot] = image;
        self.writeTextureDescriptor(slot, image.vk_imageview, sampler);
        return handle;
    };
    // TEMP-COMMENT: the cap assert you asked for; descriptor array in the shader is max_textures big.
    std.debug.assert(self.images.items.len < max_textures);
    try self.images.append(gpa, image);
    const slot: u32 = @intCast(self.images.items.len - 1);
    self.writeTextureDescriptor(slot, image.vk_imageview, sampler);
    if (key) |new_key| try self.texture_keys.put(gpa, try gpa.dupe(u8, new_key), @enumFromInt(slot));
    // TEMP-COMMENT: running texture count print you asked for.
    std.log.debug("texture {d}/{d}: {s}", .{ slot + 1, max_textures, key orelse "unnamed" });
    return @enumFromInt(slot);
}

// TEMP-COMMENT: gltf materials can pair an image with their own sampler (nearest-filter etc.);
// the image is registered with the default sampler first, this rewrites the slot's descriptor
// with the material's sampler. Combined-image-sampler descriptors bake the pair together.
pub fn setTextureSampler(self: *Resources, handle: Image.Handle, sampler: c.VkSampler) void {
    const slot = @intFromEnum(handle);
    self.writeTextureDescriptor(slot, self.images.items[slot].vk_imageview, sampler);
}

// TEMP-COMMENT: path is relative to assets/ (same convention as asset_server.watch), deduped by
// path → second loadTexture of the same file returns the same handle without touching disk.
pub fn loadTexture(self: *Resources, gpa: std.mem.Allocator, asset_server: *AssetServer, path: []const u8) !Image.Handle {
    if (self.texture_keys.get(path)) |handle| return handle;

    var uri_buffer: [256]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(&uri_buffer, "assets/{s}", .{path});
    var decoded: Image.Decoded = .{};
    defer decoded.deinit();
    var decode_tasks = [_]Image.DecodeTask{.{ .result = &decoded, .uri = uri }};
    try Image.decodeImages(gpa, &decode_tasks);
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;

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

    const handle = try self.registerImage(gpa, path, image, self.samplers.items[0]);
    // TEMP-COMMENT: watch needs a string that outlives this call → reuse the key the map duped.
    try asset_server.watch(Resources, self, self.texture_keys.getKey(path).?, reloadTexture);
    return handle;
}

// TEMP-COMMENT: replaces reloadUiTexture's comptime enum loop with a map lookup. Builds a fresh
// image and slot-overrides via registerImage → the old same-size-only restriction is gone
// (resize = new image at same slot, descriptor rewritten).
fn reloadTexture(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    const self: *Resources = @ptrCast(@alignCast(user_data));
    if (self.texture_keys.get(file_path) == null) return;

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
    _ = try self.registerImage(gpa, file_path, image, self.samplers.items[0]);
}

pub fn createStaticMesh(self: *Resources, gpa: std.mem.Allocator, name: []const u8, vertices: []const Mesh.StaticVertex, indices: []const u32, model_kind: Model.Kind) !void {
    try self.createStaticMeshWithTexture(gpa, name, vertices, indices, model_kind, .blank);
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

    // TEMP-COMMENT: generated texture goes through the same pool door as file textures;
    // keyed so a second call (hot-reload recreate) overrides the slot instead of appending.
    const texture_handle = try self.registerImage(gpa, "explosion_particle", texture, self.samplers.items[0]);
    try self.createStaticMeshWithTexture(
        gpa,
        "explosion_particle",
        Mesh.explosion_particle.verticies,
        Mesh.explosion_particle.indicies,
        .explosion_particle,
        texture_handle,
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

fn createStaticMeshWithTexture(
    self: *Resources,
    gpa: std.mem.Allocator,
    name: []const u8,
    vertices: []const Mesh.StaticVertex,
    indices: []const u32,
    model_kind: Model.Kind,
    texture: Image.Handle,
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

    const model = self.models.getPtr(model_kind);
    model.clear(gpa);
    try model.surfaces.append(gpa, .{ .mesh_id = mesh_id, .model_matrix = .identity });
    model.offset = .{};
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

    // TEMP-COMMENT: what Material.init used to do, inlined for the ONE remaining user —
    // a single-descriptor buffer for the cube sampler (can't live in the sampler2D array).
    self.skybox_descriptor = try .init(
        self.device,
        self.vma,
        u8,
        self.set_size,
        c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
            c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
    );
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = self.samplers.items[0],
        .imageView = self.skybox.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const descriptor_get_info: c.VkDescriptorGetInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .data = .{ .pCombinedImageSampler = &image_info },
    };
    const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.skybox_descriptor.info.pMappedData);
    ext.vkGetDescriptorEXT(
        self.device.handle,
        &descriptor_get_info,
        self.combined_image_sampler_descriptor_size,
        descriptor_buffer_bytes,
    );
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

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    for (self.images.items) |*image| {
        image.deinit(vma, device);
    }
    self.images.deinit(gpa);
    self.skybox.deinit(vma, device);
    self.skybox_descriptor.deinit(vma);

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
    self.texture_descriptor_buffer.deinit(vma);
    self.identity_joint_buffer.deinit(vma);
    // TEMP-COMMENT: pool owns duped key strings; images themselves are destroyed in the
    // images loop above (font atlas included — Font.deinit no longer destroys its image).
    var key_iterator = self.texture_keys.keyIterator();
    while (key_iterator.next()) |texture_key| gpa.free(texture_key.*);
    self.texture_keys.deinit(gpa);
    self.font.deinit(gpa, vma, device);
    gpa.destroy(self);
}

pub fn getMeshPtr(self: *Resources, index: usize) *Mesh {
    return &self.meshes.items[index];
}
