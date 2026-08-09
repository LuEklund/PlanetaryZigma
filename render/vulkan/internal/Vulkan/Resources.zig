const Resources = @This();

const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const nz = @import("numz");
const Vma = @import("Vma.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const DescriptorLayout = @import("DescriptorLayout.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("render").Shader;
const FrameData = @import("FrameData.zig");
const TextureTable = @import("TextureTable.zig");
const contract = @import("render");
const Shaders = @import("Shaders.zig");
const DrawList = @import("render").DrawList;
const Mesh = @import("../Vulkan/Mesh.zig");

const check = @import("utils.zig").check;

pub const max_textures = 256;

pub const shadow_cascade_count = 3;
pub const shadow_map_size: u32 = 2048;

pub const GPUCascades = extern struct {
    light_view_proj: [shadow_cascade_count][16]f32,
    splits: [4]f32,
};

gpa: std.mem.Allocator,
vma: Vma,
device: Device,

texture_table: TextureTable,
/// The GPU arrays themselves. A mesh handle is `index + 1`, so 0 stays `.none`; a texture
/// is keyed by the descriptor slot, because that slot is the only name the producer holds.
meshes: std.ArrayList(?Mesh),
textures: std.AutoArrayHashMapUnmanaged(u32, Image),
/// Bound wherever nothing has been uploaded yet, and never freed.
blank_texture: Image,
/// The checkerboard: a decode that failed is visible, not white and not stale.
missing_texture: Image,
shaders: Shaders,

descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayout.Kind, PipelineLayout),

identity_joint_buffer: Buffer,
ui_index_buffer: Buffer,

shadow_image: Image,
shadow_sampler: c.VkSampler,
shadow_descriptor_buffers: [FrameData.max_frames_inflight]Buffer,
shadow_cascade_offset: c.VkDeviceSize,

pub fn init(gpa: std.mem.Allocator, vma: Vma, physical_device: PhysicalDevice, device: Device, first_dynamic_texture_slot: u32) !*Resources {
    const descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout) = .init(.{
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
        c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
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
            physical_device.combined_image_sampler_descriptor_size,
            shadow_descriptor_bytes + shadow_sampler_offset,
        );
    }

    const self = try gpa.create(Resources);
    self.* = .{
        .texture_table = undefined,
        .meshes = .empty,
        .textures = .empty,
        .blank_texture = undefined,
        .missing_texture = undefined,
        .shaders = undefined,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .identity_joint_buffer = identity_joint_buffer,
        .ui_index_buffer = ui_index_buffer,
        .shadow_image = shadow_image,
        .shadow_sampler = shadow_sampler,
        .shadow_descriptor_buffers = shadow_descriptor_buffers,
        .shadow_cascade_offset = shadow_cascade_offset,
        .gpa = gpa,
        .vma = vma,
        .device = device,
    };
    self.texture_table = try .init(
        gpa,
        vma,
        device,
        descriptor_layouts.get(.textures).handle,
        descriptor_layouts.get(.material).handle,
        physical_device.combined_image_sampler_descriptor_size,
        first_dynamic_texture_slot,
    );
    try self.shaders.init(gpa, device, .init(.{
        .scene = descriptor_layouts.get(.scene).handle,
        .material = descriptor_layouts.get(.material).handle,
        .textures = descriptor_layouts.get(.textures).handle,
        .shadow = descriptor_layouts.get(.shadow).handle,
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
    self.texture_table.write(contract.missing_texture, missing.vk_imageview, self.texture_table.samplers.items[0]);

    self.blank_texture = blank;
    self.missing_texture = missing;

    return self;
}

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    check(c.vkDeviceWaitIdle(device.handle)) catch {};
    for (self.meshes.items) |*slot| if (slot.*) |*item| item.deinit(gpa, vma);
    self.meshes.deinit(gpa);
    for (self.textures.values()) |*image| image.deinit(vma, device);
    self.textures.deinit(gpa);
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
    self.shadow_image.deinit(vma, device);
    c.vkDestroySampler(device.handle, self.shadow_sampler, null);
    for (&self.shadow_descriptor_buffers) |*shadow_descriptor_buffer| shadow_descriptor_buffer.deinit(vma);
    gpa.destroy(self);
}

pub fn writeCascades(self: *Resources, frame_index: usize, cascades: *const GPUCascades) void {
    const bytes: [*]u8 = @ptrCast(self.shadow_descriptor_buffers[frame_index].info.pMappedData);
    @memcpy(
        bytes[self.shadow_cascade_offset..][0..@sizeOf(GPUCascades)],
        @as([*]const u8, @ptrCast(cascades))[0..@sizeOf(GPUCascades)],
    );
}


pub fn meshAt(self: *Resources, handle: contract.MeshHandle) ?*Mesh {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.meshes.items.len) return null;
    if (self.meshes.items[raw - 1]) |*mesh| return mesh;
    return null;
}

pub fn freeMesh(self: *Resources, handle: contract.MeshHandle) void {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.meshes.items.len) return;
    const slot = &self.meshes.items[raw - 1];
    if (slot.*) |*mesh| {
        check(c.vkDeviceWaitIdle(self.texture_table.device.handle)) catch {};
        mesh.deinit(self.gpa, self.texture_table.vma);
    }
    slot.* = null;
}

/// Build the GPU half from an upload command. No parser types cross: geometry arrives as
/// bytes and `MeshUpload.skinned` says which layout to read the bytes as.
pub fn uploadMesh(self: *Resources, old: contract.MeshHandle, command: *const contract.MeshUpload) !contract.MeshHandle {
    const gpa = self.gpa;
    const surfaces = try gpa.alloc(Mesh.GeoSurface, command.surfaces.len);
    defer gpa.free(surfaces);
    for (command.surfaces, surfaces) |src, *surface| surface.* = .{
        .index_start = src.index_start,
        .index_count = src.index_count,
        .texture = @enumFromInt(src.texture_slot),
    };

    const mesh: Mesh = if (command.skinned)
        try .init(gpa, self.texture_table.vma, command.name, self.texture_table.device, Mesh.SkinnedVertex, verticesAs(Mesh.SkinnedVertex, command.vertices), command.indices, surfaces)
    else
        try .init(gpa, self.texture_table.vma, command.name, self.texture_table.device, Mesh.StaticVertex, verticesAs(Mesh.StaticVertex, command.vertices), command.indices, surfaces);

    // Reuse the old row so a reloaded mesh keeps its handle and callers need no fixup.
    const raw = @intFromEnum(old);
    if (raw != 0 and raw <= self.meshes.items.len) {
        self.freeMesh(old);
        self.meshes.items[raw - 1] = mesh;
        return old;
    }
    try self.meshes.append(gpa, mesh);
    return @enumFromInt(self.meshes.items.len);
}

pub fn freeTexture(self: *Resources, slot: u32) void {
    const entry = self.textures.fetchSwapRemove(slot) orelse return;
    var image = entry.value;
    check(c.vkDeviceWaitIdle(self.texture_table.device.handle)) catch {};
    image.deinit(self.texture_table.vma, self.texture_table.device);
    self.texture_table.free(self.gpa, slot);
}

pub fn uploadTexture(self: *Resources, desc: TextureDesc) !u32 {
    const table = &self.texture_table;
    const slot: u32 = desc.slot orelse @intCast(table.alloc());

    if (desc.faces.len == 0) {
        self.dropTexture(slot);
        table.write(slot, self.missing_texture.vk_imageview, table.samplers.items[0]);
        return slot;
    }

    const cubemap = desc.faces.len == 6;
    const usage: u32 = if (desc.mips)
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
    else
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const channels: u32 = if (desc.r8) 1 else 4;
    var image: Image = try .init(
        table.vma,
        table.device,
        if (desc.r8) c.VK_FORMAT_R8_UNORM else c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = desc.width, .height = desc.height, .depth = 1 },
        if (cubemap) .cube_map else .@"2d",
        usage,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        desc.mips,
    );
    errdefer image.deinit(table.vma, table.device);

    if (desc.mips) {
        var upload_buffers: std.ArrayList(Buffer) = .empty;
        defer {
            for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(table.vma);
            upload_buffers.deinit(self.gpa);
        }
        const cmd = try table.device.beginImmediateCommand();
        for (desc.faces) |face| {
            try image.recordUploadDataToImage(self.gpa, table.vma, table.device, cmd, face.ptr, 0, channels, &upload_buffers);
        }
        try table.device.endImmediateCommand(cmd);
    } else {
        for (desc.faces, 0..) |face, layer| {
            try image.uploadDataToImage(table.vma, table.device, face.ptr, channels, @intCast(layer));
        }
    }

    const sampler = if (desc.mag_linear and desc.min_linear)
        table.samplers.items[0]
    else
        try table.addSampler(self.gpa, desc.mag_linear, desc.min_linear);

    self.dropTexture(slot);
    try self.textures.put(self.gpa, slot, image);
    if (cubemap) table.writeSkybox(image.vk_imageview, sampler) else table.write(slot, image.vk_imageview, sampler);
    return slot;
}

pub const TextureDesc = struct {
    /// null asks the store to name it — that is what makes a handle a handle.
    slot: ?u32,
    width: u32,
    height: u32,
    /// Zero faces binds the checkerboard; one is a 2D image; six is a cubemap in Vulkan
    /// face order, which goes to the skybox descriptor rather than a table slot.
    faces: []const []const u8,
    r8: bool,
    mips: bool,
    mag_linear: bool,
    min_linear: bool,
};

/// Drop the GPU image in a slot but keep the slot: the caller is about to rewrite it.
fn dropTexture(self: *Resources, slot: u32) void {
    const entry = self.textures.fetchSwapRemove(slot) orelse return;
    var image = entry.value;
    check(c.vkDeviceWaitIdle(self.texture_table.device.handle)) catch {};
    image.deinit(self.texture_table.vma, self.texture_table.device);
}

fn verticesAs(comptime VertexType: type, bytes: []const u8) []const VertexType {
    return @alignCast(std.mem.bytesAsSlice(VertexType, bytes));
}
