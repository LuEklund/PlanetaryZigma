const Resources = @This();

const std = @import("std");
const vk = @import("vulkan");
const nz = @import("numz");
const GpuMemory = @import("GpuMemory.zig");
const Device = @import("device.zig").Logical;
const DescriptorLayout = @import("DescriptorLayout.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("renderer_contract").Shader;
const Frame = @import("Frame.zig");
const TextureTable = @import("TextureTable.zig");
const contract = @import("renderer_contract");
const Shaders = @import("Shaders.zig");
const DrawList = contract.DrawList;
const Mesh = @import("Mesh.zig");
const box = @import("../box.zig");

pub const max_textures = TextureTable.max_textures;

pub const shadow_cascade_count = 3;
pub const shadow_map_size: u32 = 2048;
pub const shadow_format: vk.Format = .d32_sfloat;

pub const RetiredMesh = struct {
    mesh: Mesh,
    frame: u32,
};

pub const RetiredImage = struct {
    image: Image,
    texture: ?contract.TextureHandle,
    frame: u32,
};

pub const GPUCascades = extern struct {
    light_view_proj: [shadow_cascade_count][16]f32,
    splits: [4]f32,
};

const frame_count = Frame.max_frames_inflight;

gpa: std.mem.Allocator,
device: Device,

texture_table: TextureTable,
meshes: std.ArrayList(?Mesh),
textures: std.AutoArrayHashMapUnmanaged(contract.TextureHandle, Image),
retired_meshes: std.ArrayList(RetiredMesh),
retired_images: std.ArrayList(RetiredImage),

blank_texture: Image,
default_mesh: contract.MeshHandle,
skybox_image: ?Image,
missing_texture: Image,
shaders: Shaders,

descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayout.Kind, PipelineLayout),

identity_joint_buffer: Buffer,
effect_params_buffer: Buffer,

shadow_image: Image,
shadow_sampler: vk.Sampler,
cascade_buffers: [frame_count]Buffer,

descriptor_pool: vk.DescriptorPool,
scene_sets: [frame_count]vk.DescriptorSet,
shadow_sets: [frame_count]vk.DescriptorSet,

pub fn init(gpa: std.mem.Allocator, heaps: *GpuMemory.Heaps, device: Device) !*Resources {
    const vertex_fragment: vk.ShaderStageFlags = .{ .vertex_bit = true, .fragment_bit = true };
    const fragment: vk.ShaderStageFlags = .{ .fragment_bit = true };
    const descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout) = .init(.{
        .scene = try .init(device, &.{
            .{ .binding = 0, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .stage_flags = vertex_fragment },
        }, .{}, null),
        .material = try .init(device, &.{
            .{ .binding = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .stage_flags = vertex_fragment },
        }, .{}, null),
        .shadow = try .init(device, &.{
            .{ .binding = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .stage_flags = fragment },
            .{ .binding = 1, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .stage_flags = fragment },
        }, .{}, null),
        .textures = try .init(device, &.{
            .{ .binding = 0, .descriptor_count = max_textures, .descriptor_type = .combined_image_sampler, .stage_flags = vertex_fragment },
        }, .{ .update_after_bind_pool_bit = true }, &.{
            .{ .update_after_bind_bit = true, .update_unused_while_pending_bit = true, .partially_bound_bit = true },
        }),
    });

    const pipeline_layouts: std.EnumArray(PipelineLayout.Kind, PipelineLayout) = .init(.{
        .world = try .init(device, @sizeOf(Shader.WorldPushConstant), &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.textures).handle,
            descriptor_layouts.get(.shadow).handle,
        }),
        .particle = try .init(device, @sizeOf(Shader.ParticlePushConstant), &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.textures).handle,
            descriptor_layouts.get(.shadow).handle,
        }),
        .sky = try .init(device, 0, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.material).handle,
        }),
        .dvui = try .init(device, @sizeOf(Shader.DvuiPushConstant), &.{
            descriptor_layouts.get(.textures).handle,
        }),
    });

    var identity_joint_buffer: Buffer = try .init(device, &heaps.host, nz.Mat4x4(f32), 1, .{ .uniform_buffer_bit = true, .storage_buffer_bit = true, .shader_device_address_bit = true });
    identity_joint_buffer.copy(nz.Mat4x4(f32), &.{.identity});

    var effect_params_buffer: Buffer = try .init(device, &heaps.host, contract.Effect.GPU, contract.ParticleEffect.count, .{ .storage_buffer_bit = true, .shader_device_address_bit = true });
    var effect_params_rows: [contract.ParticleEffect.count]contract.Effect.GPU = undefined;
    for (std.enums.values(contract.ParticleEffect)) |effect| {
        effect_params_rows[@intFromEnum(effect)] = contract.effects.get(effect).toGPU();
    }
    effect_params_buffer.copy(contract.Effect.GPU, &effect_params_rows);

    const shadow_image: Image = try .init(
        &heaps.device,
        device,
        shadow_format,
        .{ .width = shadow_map_size * shadow_cascade_count, .height = shadow_map_size, .depth = 1 },
        .@"2d",
        .{ .depth_stencil_attachment_bit = true, .sampled_bit = true },
        .{ .depth_bit = true },
        false,
    );
    const shadow_sampler = try device.proxy.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .true,
        .compare_op = .less_or_equal,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_white,
        .unnormalized_coordinates = .false,
    }, null);

    var cascade_buffers: [frame_count]Buffer = undefined;
    for (&cascade_buffers) |*cascade_buffer| cascade_buffer.* = try .init(device, &heaps.host, GPUCascades, 1, .{ .uniform_buffer_bit = true });

    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .uniform_buffer, .descriptor_count = frame_count * 2 },
        .{ .type = .combined_image_sampler, .descriptor_count = max_textures + 1 + frame_count },
    };
    const descriptor_pool = try device.proxy.createDescriptorPool(&.{
        .flags = .{ .update_after_bind_bit = true },
        .max_sets = frame_count * 2 + 2,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = &pool_sizes,
    }, null);

    var scene_sets: [frame_count]vk.DescriptorSet = undefined;
    var shadow_sets: [frame_count]vk.DescriptorSet = undefined;
    const scene_layouts: [frame_count]vk.DescriptorSetLayout = @splat(descriptor_layouts.get(.scene).handle);
    const shadow_layouts: [frame_count]vk.DescriptorSetLayout = @splat(descriptor_layouts.get(.shadow).handle);
    try device.proxy.allocateDescriptorSets(&.{ .descriptor_pool = descriptor_pool, .descriptor_set_count = frame_count, .p_set_layouts = &scene_layouts }, &scene_sets);
    try device.proxy.allocateDescriptorSets(&.{ .descriptor_pool = descriptor_pool, .descriptor_set_count = frame_count, .p_set_layouts = &shadow_layouts }, &shadow_sets);
    for (shadow_sets, cascade_buffers) |shadow_set, cascade_buffer| {
        TextureTable.writeCombinedSampler(device, shadow_set, 0, 0, shadow_image.vk_imageview, shadow_sampler);
        TextureTable.writeUniformBuffer(device, shadow_set, 1, cascade_buffer.buffer);
    }

    const self = try gpa.create(Resources);
    self.* = .{
        .gpa = gpa,
        .device = device,
        .texture_table = try .init(device, descriptor_pool, descriptor_layouts.get(.textures).handle, descriptor_layouts.get(.material).handle),
        .meshes = .empty,
        .retired_meshes = .empty,
        .retired_images = .empty,
        .textures = .empty,
        .blank_texture = undefined,
        .default_mesh = .none,
        .skybox_image = null,
        .missing_texture = undefined,
        .shaders = .init(device, .init(.{
            .world = pipeline_layouts.get(.world).handle,
            .particle = pipeline_layouts.get(.particle).handle,
            .sky = pipeline_layouts.get(.sky).handle,
            .dvui = pipeline_layouts.get(.dvui).handle,
        })),
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .identity_joint_buffer = identity_joint_buffer,
        .effect_params_buffer = effect_params_buffer,
        .shadow_image = shadow_image,
        .shadow_sampler = shadow_sampler,
        .cascade_buffers = cascade_buffers,
        .descriptor_pool = descriptor_pool,
        .scene_sets = scene_sets,
        .shadow_sets = shadow_sets,
    };

    const white = [_]u8{ 255, 255, 255, 255 };
    self.blank_texture = try self.buildImage(heaps, &.{&white}, 1, 1, false, false, .@"2d");

    var checkerboard: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const magenta: bool = (x + y) % 2 == 0;
        checkerboard[(y * 8 + x) * 4 ..][0..4].* = if (magenta) .{ 255, 0, 255, 255 } else .{ 0, 0, 0, 255 };
    };
    self.missing_texture = try self.buildImage(heaps, &.{&checkerboard}, 8, 8, false, false, .@"2d");

    self.texture_table.registerEmpty(device, self.blank_texture.vk_imageview, self.texture_table.defaultSampler());
    self.texture_table.write(device, .missing, self.missing_texture.vk_imageview, self.texture_table.defaultSampler());

    const box_surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(box.indices.len),
        .texture = .blank,
        .transparent = false,
    }};
    self.default_mesh = try self.uploadMesh(heaps, .none, 0, &.{
        .name = "default",
        .vertices = std.mem.sliceAsBytes(box.vertices),
        .skinned = false,
        .indices = box.indices,
        .surfaces = &box_surfaces,
    });
    return self;
}

pub fn deinit(self: *Resources, heaps: *GpuMemory.Heaps) void {
    const device = self.device;
    const gpa = self.gpa;
    device.proxy.deviceWaitIdle() catch {};
    for (self.meshes.items) |*slot| if (slot.*) |*item| item.deinit(gpa, &heaps.host);
    self.meshes.deinit(gpa);
    for (self.retired_meshes.items) |*retired| retired.mesh.deinit(gpa, &heaps.host);
    self.retired_meshes.deinit(gpa);
    for (self.retired_images.items) |*retired| retired.image.deinit(&heaps.device, device);
    self.retired_images.deinit(gpa);
    for (self.textures.values()) |*image| image.deinit(&heaps.device, device);
    self.textures.deinit(gpa);
    if (self.skybox_image) |*sky| sky.deinit(&heaps.device, device);
    self.blank_texture.deinit(&heaps.device, device);
    self.missing_texture.deinit(&heaps.device, device);
    self.shaders.deinit();
    self.texture_table.deinit(device);
    for (self.descriptor_layouts.values) |layout| layout.deinit(device);
    for (self.pipeline_layouts.values) |layout| layout.deinit(device);
    self.identity_joint_buffer.deinit(&heaps.host);
    self.effect_params_buffer.deinit(&heaps.host);
    self.shadow_image.deinit(&heaps.device, device);
    device.proxy.destroySampler(self.shadow_sampler, null);
    for (&self.cascade_buffers) |*cascade_buffer| cascade_buffer.deinit(&heaps.host);
    device.proxy.destroyDescriptorPool(self.descriptor_pool, null);
    gpa.destroy(self);
}

pub fn writeCascades(self: *Resources, frame_index: usize, cascades: *const GPUCascades) void {
    self.cascade_buffers[frame_index].copy(GPUCascades, cascades[0..1]);
}

pub fn writeSceneSet(self: *Resources, frame_index: usize, scene_buffer: Buffer) void {
    TextureTable.writeUniformBuffer(self.device, self.scene_sets[frame_index], 0, scene_buffer.buffer);
}

pub fn writeTexture(self: *Resources, texture: contract.TextureHandle, view: vk.ImageView) void {
    self.texture_table.write(self.device, texture, view, self.texture_table.defaultSampler());
}

pub fn meshAt(self: *Resources, handle: contract.MeshHandle) ?*Mesh {
    return self.meshFor(handle) orelse self.meshFor(self.default_mesh);
}

fn meshFor(self: *Resources, handle: contract.MeshHandle) ?*Mesh {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.meshes.items.len) return null;
    if (self.meshes.items[raw - 1]) |*mesh| return mesh;
    return null;
}

pub fn freeMesh(self: *Resources, heaps: *GpuMemory.Heaps, handle: contract.MeshHandle, frame: u32) void {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.meshes.items.len) return;
    const slot = &self.meshes.items[raw - 1];
    if (slot.*) |mesh| {
        self.retired_meshes.append(self.gpa, .{ .mesh = mesh, .frame = frame }) catch {
            var doomed = mesh;
            self.device.proxy.deviceWaitIdle() catch {};
            doomed.deinit(self.gpa, &heaps.host);
        };
    }
    slot.* = null;
}

pub fn drainRetired(self: *Resources, heaps: *GpuMemory.Heaps, frame: u32) void {
    var index: usize = 0;
    while (index < self.retired_images.items.len) {
        if (frame < self.retired_images.items[index].frame + frame_count) {
            index += 1;
            continue;
        }
        var doomed = self.retired_images.swapRemove(index);
        doomed.image.deinit(&heaps.device, self.device);
        if (doomed.texture) |texture| self.texture_table.free(self.device, texture);
    }
    index = 0;
    while (index < self.retired_meshes.items.len) {
        if (frame < self.retired_meshes.items[index].frame + frame_count) {
            index += 1;
            continue;
        }
        var doomed = self.retired_meshes.swapRemove(index).mesh;
        doomed.deinit(self.gpa, &heaps.host);
    }
}

pub fn uploadMesh(self: *Resources, heaps: *GpuMemory.Heaps, old: contract.MeshHandle, frame: u32, command: *const contract.MeshUpload) !contract.MeshHandle {
    const gpa = self.gpa;
    const surfaces = try gpa.alloc(Mesh.Surface, command.surfaces.len);
    errdefer gpa.free(surfaces);
    var write: usize = 0;
    for (command.surfaces) |src| {
        if (src.transparent) continue;
        surfaces[write] = .{ .index_start = src.index_start, .index_count = src.index_count, .texture = src.texture };
        write += 1;
    }
    const opaque_count: u32 = @intCast(write);
    for (command.surfaces) |src| {
        if (!src.transparent) continue;
        surfaces[write] = .{ .index_start = src.index_start, .index_count = src.index_count, .texture = src.texture };
        write += 1;
    }
    std.debug.assert(write == surfaces.len);

    const mesh: Mesh = if (command.skinned)
        try .init(gpa, &heaps.host, command.name, self.device, Mesh.SkinnedVertex, verticesAs(Mesh.SkinnedVertex, command.vertices), command.indices, surfaces, opaque_count)
    else
        try .init(gpa, &heaps.host, command.name, self.device, Mesh.StaticVertex, verticesAs(Mesh.StaticVertex, command.vertices), command.indices, surfaces, opaque_count);

    const raw = @intFromEnum(old);
    if (raw != 0 and raw <= self.meshes.items.len) {
        self.freeMesh(heaps, old, frame);
        self.meshes.items[raw - 1] = mesh;
        return old;
    }
    try self.meshes.append(gpa, mesh);
    return @enumFromInt(self.meshes.items.len);
}

pub fn freeTexture(self: *Resources, heaps: *GpuMemory.Heaps, texture: contract.TextureHandle, frame: u32) void {
    const entry = self.textures.fetchSwapRemove(texture) orelse return;
    self.retire(heaps, entry.value, texture, frame);
}

fn retire(self: *Resources, heaps: *GpuMemory.Heaps, image: Image, texture: ?contract.TextureHandle, frame: u32) void {
    self.retired_images.append(self.gpa, .{ .image = image, .texture = texture, .frame = frame }) catch {
        var doomed = image;
        self.device.proxy.deviceWaitIdle() catch {};
        doomed.deinit(&heaps.device, self.device);
        if (texture) |taken| self.texture_table.free(self.device, taken);
    };
}

pub fn uploadImage(self: *Resources, heaps: *GpuMemory.Heaps, upload: *const contract.ImageUpload) !contract.TextureHandle {
    var image = try self.buildImage(heaps, &.{upload.pixels}, upload.width, upload.height, upload.r8, upload.mips, .@"2d");
    errdefer image.deinit(&heaps.device, self.device);
    const sampler = try self.samplerFor(upload.mag_linear, upload.min_linear);

    const texture = self.texture_table.alloc();
    try self.textures.put(self.gpa, texture, image);
    self.texture_table.write(self.device, texture, image.vk_imageview, sampler);
    return texture;
}

pub fn uploadSkybox(self: *Resources, heaps: *GpuMemory.Heaps, upload: *const contract.SkyboxUpload, frame: u32) !void {
    var image = try self.buildImage(heaps, &upload.faces, upload.size, upload.size, false, false, .cube_map);
    errdefer image.deinit(&heaps.device, self.device);
    if (self.skybox_image) |old| self.retire(heaps, old, null, frame);
    self.skybox_image = image;
    self.texture_table.writeSkybox(self.device, image.vk_imageview, self.texture_table.defaultSampler());
}

fn samplerFor(self: *Resources, mag_linear: bool, min_linear: bool) !vk.Sampler {
    if (mag_linear and min_linear) return self.texture_table.defaultSampler();
    return self.texture_table.addFilterSampler(self.device, mag_linear, min_linear);
}

fn buildImage(self: *Resources, heaps: *GpuMemory.Heaps, faces: []const []const u8, width: u32, height: u32, r8: bool, mips: bool, kind: Image.Kind) !Image {
    const usage: vk.ImageUsageFlags = .{ .sampled_bit = true, .transfer_dst_bit = true, .transfer_src_bit = mips };
    const bytes_per_pixel: u32 = if (r8) 1 else 4;
    var image: Image = try .init(&heaps.device, self.device, if (r8) .r8_unorm else .r8g8b8a8_unorm, .{ .width = width, .height = height, .depth = 1 }, kind, usage, .{ .color_bit = true }, mips);
    errdefer image.deinit(&heaps.device, self.device);

    const face_size: usize = width * height * bytes_per_pixel;
    var staging: Buffer = try .init(self.device, &heaps.host, u8, face_size * faces.len, .{ .transfer_src_bit = true });
    defer staging.deinit(&heaps.host);

    const cmd = try self.device.beginImmediateCommand();
    for (faces, 0..) |face, layer| {
        @memcpy(staging.mapped[face_size * layer ..][0..face_size], face[0..face_size]);
        image.recordUpload(self.device, cmd, staging, @intCast(layer), face_size * layer);
    }
    try self.device.endImmediateCommand(cmd);
    return image;
}

fn verticesAs(comptime VertexType: type, bytes: []const u8) []const VertexType {
    return @alignCast(std.mem.bytesAsSlice(VertexType, bytes));
}
