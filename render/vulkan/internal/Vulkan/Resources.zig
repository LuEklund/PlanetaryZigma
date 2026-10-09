const Resources = @This();

const std = @import("std");
const c = @import("vulkan");
const nz = @import("numz");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const DescriptorLayout = @import("DescriptorLayout.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("renderer_contract").Shader;
const FrameData = @import("FrameData.zig");
const TextureTable = @import("TextureTable.zig");
const contract = @import("renderer_contract");
const Shaders = @import("Shaders.zig");
const DrawList = contract.DrawList;
const Mesh = @import("../Vulkan/Mesh.zig");
const box = @import("../box.zig");

const check = @import("utils.zig").check;

pub const max_textures = 256;

pub const shadow_cascade_count = 3;
pub const shadow_map_size: u32 = 2048;

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

gpa: std.mem.Allocator,
vma: Vma,
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
ui_index_buffer: Buffer,

effect_params_buffer: Buffer,

shadow_image: Image,
shadow_sampler: c.VkSampler,
cascade_buffers: [FrameData.max_frames_inflight]Buffer,

descriptor_pool: c.VkDescriptorPool,
scene_sets: [FrameData.max_frames_inflight]c.VkDescriptorSet,
shadow_sets: [FrameData.max_frames_inflight]c.VkDescriptorSet,

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device) !*Resources {
    const descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout) = .init(.{
        .scene = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, 0, null),
        .material = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, 0, null),
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
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, 0, null),
        .textures = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = max_textures,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        }, c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT, &.{
            c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT | c.VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT | c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT,
        }),
    });

    const pipeline_layouts: std.EnumArray(PipelineLayout.Kind, PipelineLayout) = .init(.{
        .world = try .init(device, @sizeOf(Shader.WorldPushConstant), c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.textures).handle,
            descriptor_layouts.get(.shadow).handle,
        }),
        .particle = try .init(device, @sizeOf(Shader.ParticlePushConstant), c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.textures).handle,
            descriptor_layouts.get(.shadow).handle,
        }),
        .sky = try .init(device, 0, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, &.{
            descriptor_layouts.get(.scene).handle,
            descriptor_layouts.get(.material).handle,
        }),
        .ui = try .init(device, @sizeOf(Shader.UiPushConstant), c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, &.{
            descriptor_layouts.get(.textures).handle,
        }),
    });

    var identity_joint_buffer: Buffer = try .init(
        device,
        vma,
        nz.Mat4x4(f32),
        1,
        c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
    );
    identity_joint_buffer.copy(nz.Mat4x4(f32), &.{.identity});

    const ui_index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        DrawList.max_ui_quads * 6,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_AUTO,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | Vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    var index_data: [*]u32 = @ptrCast(@alignCast(ui_index_buffer.info.pMappedData));
    for (0..DrawList.max_ui_quads) |quad_index| {
        const base: u32 = @as(u32, @intCast(quad_index)) * 4;
        index_data[quad_index * 6 ..][0..6].* = .{ base, base + 1, base + 2, base + 2, base + 3, base };
    }

    var effect_params_buffer: Buffer = try .init(
        device,
        vma,
        contract.Effect.GPU,
        contract.ParticleEffect.count,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
    );
    var effect_params_rows: [contract.ParticleEffect.count]contract.Effect.GPU = undefined;
    for (std.enums.values(contract.ParticleEffect)) |effect| {
        effect_params_rows[@intFromEnum(effect)] = contract.effects.get(effect).toGPU();
    }
    effect_params_buffer.copy(contract.Effect.GPU, &effect_params_rows);

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

    var cascade_buffers: [FrameData.max_frames_inflight]Buffer = undefined;
    for (&cascade_buffers) |*cascade_buffer| {
        cascade_buffer.* = try .init(
            device,
            vma,
            GPUCascades,
            1,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
        );
    }

    const frame_count: u32 = FrameData.max_frames_inflight;
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = frame_count * 2 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = max_textures + 1 + frame_count },
    };
    var descriptor_pool: c.VkDescriptorPool = null;
    try check(c.vkCreateDescriptorPool(device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
        .maxSets = frame_count * 2 + 2,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    }, null, &descriptor_pool));

    var scene_sets: [FrameData.max_frames_inflight]c.VkDescriptorSet = undefined;
    var shadow_sets: [FrameData.max_frames_inflight]c.VkDescriptorSet = undefined;
    const scene_layouts: [FrameData.max_frames_inflight]c.VkDescriptorSetLayout = @splat(descriptor_layouts.get(.scene).handle);
    const shadow_layouts: [FrameData.max_frames_inflight]c.VkDescriptorSetLayout = @splat(descriptor_layouts.get(.shadow).handle);
    try check(c.vkAllocateDescriptorSets(device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = frame_count,
        .pSetLayouts = &scene_layouts,
    }, &scene_sets));
    try check(c.vkAllocateDescriptorSets(device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = frame_count,
        .pSetLayouts = &shadow_layouts,
    }, &shadow_sets));

    for (shadow_sets, cascade_buffers) |shadow_set, cascade_buffer| {
        TextureTable.writeCombinedSampler(device, shadow_set, 0, shadow_image.vk_imageview, shadow_sampler);
        writeUniformBuffer(device, shadow_set, 1, cascade_buffer);
    }

    const self = try gpa.create(Resources);
    self.* = .{
        .texture_table = undefined,
        .meshes = .empty,
        .retired_meshes = .empty,
        .retired_images = .empty,
        .textures = .empty,
        .blank_texture = undefined,
        .default_mesh = .none,
        .skybox_image = null,
        .missing_texture = undefined,
        .shaders = undefined,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .identity_joint_buffer = identity_joint_buffer,
        .ui_index_buffer = ui_index_buffer,
        .effect_params_buffer = effect_params_buffer,
        .shadow_image = shadow_image,
        .shadow_sampler = shadow_sampler,
        .cascade_buffers = cascade_buffers,
        .descriptor_pool = descriptor_pool,
        .scene_sets = scene_sets,
        .shadow_sets = shadow_sets,
        .gpa = gpa,
        .vma = vma,
        .device = device,
    };
    self.texture_table = try .init(
        gpa,
        vma,
        device,
        descriptor_pool,
        descriptor_layouts.get(.textures).handle,
        descriptor_layouts.get(.material).handle,
    );
    self.shaders = .init(device, .init(.{
        .world = pipeline_layouts.get(.world).handle,
        .particle = pipeline_layouts.get(.particle).handle,
        .sky = pipeline_layouts.get(.sky).handle,
        .ui = pipeline_layouts.get(.ui).handle,
    }));

    var blank: Image = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 1, .height = 1, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var white: [4]u8 = .{ 255, 255, 255, 255 };
    try blank.uploadDataToImage(self.vma, self.device, &white, 4, 0);

    var missing: Image = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 8, .height = 8, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var checkerboard: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const magenta: bool = (x + y) % 2 == 0;
        checkerboard[(y * 8 + x) * 4 + 0] = if (magenta) 255 else 0;
        checkerboard[(y * 8 + x) * 4 + 1] = 0;
        checkerboard[(y * 8 + x) * 4 + 2] = if (magenta) 255 else 0;
        checkerboard[(y * 8 + x) * 4 + 3] = 255;
    };
    try missing.uploadDataToImage(self.vma, self.device, &checkerboard, checkerboard.len, 0);

    self.texture_table.registerEmpty(blank.vk_imageview, self.texture_table.samplers.items[0]);
    self.texture_table.write(.missing, missing.vk_imageview, self.texture_table.samplers.items[0]);

    self.blank_texture = blank;
    self.missing_texture = missing;

    const box_surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(box.indices.len),
        .texture = .blank,
        .transparent = false,
    }};
    const box_handle = try self.uploadMesh(.none, 0, &.{
        .name = "default",
        .vertices = std.mem.sliceAsBytes(box.vertices),
        .skinned = false,
        .indices = box.indices,
        .surfaces = &box_surfaces,
    });
    self.default_mesh = box_handle;

    return self;
}

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    check(c.vkDeviceWaitIdle(device.handle)) catch {};
    for (self.meshes.items) |*slot| if (slot.*) |*item| item.deinit(gpa, vma);
    self.meshes.deinit(gpa);
    for (self.retired_meshes.items) |*retired| retired.mesh.deinit(gpa, vma);
    self.retired_meshes.deinit(gpa);
    for (self.retired_images.items) |*retired| retired.image.deinit(vma, device);
    self.retired_images.deinit(gpa);
    for (self.textures.values()) |*image| image.deinit(vma, device);
    self.textures.deinit(gpa);
    if (self.skybox_image) |*sky| sky.deinit(vma, device);
    self.blank_texture.deinit(vma, device);
    self.missing_texture.deinit(vma, device);
    self.shaders.deinit();
    self.texture_table.deinit(gpa);
    for (self.descriptor_layouts.values) |layout| {
        layout.deinit(device);
    }
    for (&self.pipeline_layouts.values) |*layout| {
        layout.deinit(device);
    }
    self.identity_joint_buffer.deinit(vma);
    self.ui_index_buffer.deinit(vma);
    self.effect_params_buffer.deinit(vma);
    self.shadow_image.deinit(vma, device);
    c.vkDestroySampler(device.handle, self.shadow_sampler, null);
    for (&self.cascade_buffers) |*cascade_buffer| cascade_buffer.deinit(vma);
    c.vkDestroyDescriptorPool(device.handle, self.descriptor_pool, null);
    gpa.destroy(self);
}

pub fn writeCascades(self: *Resources, frame_index: usize, cascades: *const GPUCascades) void {
    self.cascade_buffers[frame_index].copy(GPUCascades, cascades[0..1]);
}

pub fn writeSceneSet(self: *Resources, frame_index: usize, scene_buffer: Buffer) void {
    writeUniformBuffer(self.device, self.scene_sets[frame_index], 0, scene_buffer);
}

fn writeUniformBuffer(device: Device, set: c.VkDescriptorSet, binding: u32, buffer: Buffer) void {
    const buffer_info: c.VkDescriptorBufferInfo = .{
        .buffer = buffer.buffer,
        .offset = 0,
        .range = c.VK_WHOLE_SIZE,
    };
    const descriptor_write: c.VkWriteDescriptorSet = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstBinding = binding,
        .descriptorCount = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pBufferInfo = &buffer_info,
    };
    c.vkUpdateDescriptorSets(device.handle, 1, &descriptor_write, 0, null);
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

pub fn freeMesh(self: *Resources, handle: contract.MeshHandle, frame: u32) void {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.meshes.items.len) return;
    const slot = &self.meshes.items[raw - 1];
    if (slot.*) |mesh| {
        self.retired_meshes.append(self.gpa, .{ .mesh = mesh, .frame = frame }) catch {
            var doomed = mesh;
            check(c.vkDeviceWaitIdle(self.texture_table.device.handle)) catch {};
            doomed.deinit(self.gpa, self.texture_table.vma);
        };
    }
    slot.* = null;
}

pub fn drainRetired(self: *Resources, frame: u32) void {
    self.drainRetiredImages(frame);
    self.drainRetiredMeshes(frame);
}

fn drainRetiredImages(self: *Resources, frame: u32) void {
    var index: usize = 0;
    while (index < self.retired_images.items.len) {
        const retired = &self.retired_images.items[index];
        if (frame < retired.frame + FrameData.max_frames_inflight) {
            index += 1;
            continue;
        }
        var doomed = self.retired_images.swapRemove(index);
        doomed.image.deinit(self.texture_table.vma, self.texture_table.device);
        if (doomed.texture) |texture| self.texture_table.free(texture);
    }
}

fn drainRetiredMeshes(self: *Resources, frame: u32) void {
    var index: usize = 0;
    while (index < self.retired_meshes.items.len) {
        const retired = &self.retired_meshes.items[index];
        if (frame < retired.frame + FrameData.max_frames_inflight) {
            index += 1;
            continue;
        }
        var doomed = self.retired_meshes.swapRemove(index).mesh;
        doomed.deinit(self.gpa, self.texture_table.vma);
    }
}

pub fn uploadMesh(self: *Resources, old: contract.MeshHandle, frame: u32, command: *const contract.MeshUpload) !contract.MeshHandle {
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
        try .init(
            gpa,
            self.texture_table.vma,
            command.name,
            self.texture_table.device,
            Mesh.SkinnedVertex,
            verticesAs(Mesh.SkinnedVertex, command.vertices),
            command.indices,
            surfaces,
            opaque_count,
        )
    else
        try .init(
            gpa,
            self.texture_table.vma,
            command.name,
            self.texture_table.device,
            Mesh.StaticVertex,
            verticesAs(Mesh.StaticVertex, command.vertices),
            command.indices,
            surfaces,
            opaque_count,
        );

    const raw = @intFromEnum(old);
    if (raw != 0 and raw <= self.meshes.items.len) {
        self.freeMesh(old, frame);
        self.meshes.items[raw - 1] = mesh;
        return old;
    }
    try self.meshes.append(gpa, mesh);
    return @enumFromInt(self.meshes.items.len);
}

pub fn freeTexture(self: *Resources, texture: contract.TextureHandle, frame: u32) void {
    const entry = self.textures.fetchSwapRemove(texture) orelse return;
    self.retire(entry.value, texture, frame);
}

fn retire(self: *Resources, image: Image, texture: ?contract.TextureHandle, frame: u32) void {
    self.retired_images.append(self.gpa, .{ .image = image, .texture = texture, .frame = frame }) catch {
        var doomed = image;
        check(c.vkDeviceWaitIdle(self.texture_table.device.handle)) catch {};
        doomed.deinit(self.texture_table.vma, self.texture_table.device);
        if (texture) |taken| self.texture_table.free(taken);
    };
}

pub fn uploadImage(self: *Resources, upload: *const contract.ImageUpload) !contract.TextureHandle {
    const table = &self.texture_table;
    var image = try self.buildImage(&.{upload.pixels}, upload.width, upload.height, upload.r8, upload.mips, .@"2d");
    errdefer image.deinit(table.vma, table.device);
    const sampler = try self.samplerFor(upload.mag_linear, upload.min_linear);

    const texture = table.alloc();
    try self.textures.put(self.gpa, texture, image);
    table.write(texture, image.vk_imageview, sampler);
    return texture;
}

pub fn uploadSkybox(self: *Resources, upload: *const contract.SkyboxUpload, frame: u32) !void {
    const table = &self.texture_table;
    var image = try self.buildImage(&upload.faces, upload.size, upload.size, false, false, .cube_map);
    errdefer image.deinit(table.vma, table.device);
    const sampler = try self.samplerFor(true, true);

    if (self.skybox_image) |old| self.retire(old, null, frame);
    self.skybox_image = image;
    table.writeSkybox(image.vk_imageview, sampler);
}

fn samplerFor(self: *Resources, mag_linear: bool, min_linear: bool) !c.VkSampler {
    const table = &self.texture_table;
    if (mag_linear and min_linear) return table.samplers.items[0];
    return table.addSampler(self.gpa, mag_linear, min_linear);
}

fn buildImage(self: *Resources, faces: []const []const u8, width: u32, height: u32, r8: bool, mips: bool, kind: Image.Kind) !Image {
    const table = &self.texture_table;
    const usage: u32 = if (mips)
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
    else
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const channels: u32 = if (r8) 1 else 4;
    var image: Image = try .init(
        table.vma,
        table.device,
        if (r8) c.VK_FORMAT_R8_UNORM else c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = width, .height = height, .depth = 1 },
        kind,
        usage,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        mips,
    );
    errdefer image.deinit(table.vma, table.device);

    if (mips) {
        var upload_buffers: std.ArrayList(Buffer) = .empty;
        defer {
            for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(table.vma);
            upload_buffers.deinit(self.gpa);
        }
        const cmd = try table.device.beginImmediateCommand();
        for (faces) |face| {
            try image.recordUploadDataToImage(self.gpa, table.vma, table.device, cmd, face.ptr, 0, channels, &upload_buffers);
        }
        try table.device.endImmediateCommand(cmd);
    } else {
        for (faces, 0..) |face, layer| {
            try image.uploadDataToImage(table.vma, table.device, face.ptr, channels, @intCast(layer));
        }
    }

    return image;
}

fn verticesAs(comptime VertexType: type, bytes: []const u8) []const VertexType {
    return @alignCast(std.mem.bytesAsSlice(VertexType, bytes));
}
