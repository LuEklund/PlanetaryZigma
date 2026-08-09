const Resources = @This();

const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const DescriptorLayout = @import("DescriptorLayout.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const Image = @import("Image.zig");
const Buffer = @import("Buffer.zig");
const Shader = @import("shared").Shader;
const FrameData = @import("FrameData.zig");
const Ui = @import("shared").Ui;
const TextureTable = @import("TextureTable.zig");
const Meshes = @import("Meshes.zig");
const Textures = @import("Textures.zig");
const Shaders = @import("Shaders.zig");
const Fonts = @import("Fonts.zig");
const Font = @import("shared").Font;
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

vma: Vma,
device: Device,

texture_table: TextureTable,
meshes: *Meshes,
textures: *Textures,
shaders: *Shaders,
fonts: *Fonts,
generated: [DrawList.max_generated]Mesh,

descriptor_layouts: std.EnumArray(Shader.Descriptor, DescriptorLayout),
pipeline_layouts: std.EnumArray(PipelineLayout.Kind, PipelineLayout),

identity_joint_buffer: Buffer,
ui_index_buffer: Buffer,

shadow_image: Image,
shadow_sampler: c.VkSampler,
shadow_descriptor_buffers: [FrameData.max_frames_inflight]Buffer,
shadow_cascade_offset: c.VkDeviceSize,

pub fn init(gpa: std.mem.Allocator, fonts: []Font, vma: Vma, physical_device: PhysicalDevice, device: Device) !*Resources {
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
        Ui.max_ui_quads * 6,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_AUTO,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | Vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    var index_data: [*]u32 = @ptrCast(@alignCast(ui_index_buffer.info.pMappedData));
    for (0..Ui.max_ui_quads) |quad_index| {
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
        .meshes = undefined,
        .textures = undefined,
        .shaders = undefined,
        .fonts = undefined,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .identity_joint_buffer = identity_joint_buffer,
        .ui_index_buffer = ui_index_buffer,
        .shadow_image = shadow_image,
        .shadow_sampler = shadow_sampler,
        .shadow_descriptor_buffers = shadow_descriptor_buffers,
        .shadow_cascade_offset = shadow_cascade_offset,
        .vma = vma,
        .device = device,
        .generated = undefined,
    };
    self.texture_table = try .init(
        gpa,
        vma,
        device,
        descriptor_layouts.get(.textures).handle,
        descriptor_layouts.get(.material).handle,
        physical_device.combined_image_sampler_descriptor_size,
    );
    self.meshes = try gpa.create(Meshes);
    try self.meshes.init(gpa, &self.texture_table);
    self.textures = try gpa.create(Textures);
    try self.textures.init(gpa, &self.texture_table);
    self.shaders = try gpa.create(Shaders);
    try self.shaders.init(gpa, device, .init(.{
        .scene = descriptor_layouts.get(.scene).handle,
        .material = descriptor_layouts.get(.material).handle,
        .textures = descriptor_layouts.get(.textures).handle,
        .shadow = descriptor_layouts.get(.shadow).handle,
    }));
    self.fonts = try gpa.create(Fonts);
    try self.fonts.init(gpa, &self.texture_table, fonts);

    for (&self.generated) |*mesh| mesh.* = try makeBoxMesh(gpa, self.vma, self.device, "generated");

    return self;
}

pub fn deinit(self: *Resources, gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    self.meshes.deinit();
    gpa.destroy(self.meshes);
    self.textures.deinit();
    gpa.destroy(self.textures);
    self.fonts.deinit();
    gpa.destroy(self.fonts);
    self.shaders.deinit();
    gpa.destroy(self.shaders);
    self.texture_table.deinit(gpa);
    for (&self.generated) |*mesh| mesh.deinit(gpa, self.vma);
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

fn makeBoxMesh(gpa: std.mem.Allocator, vma: Vma, device: Device, name: []const u8) !Mesh {
    return try .init(gpa, vma, name, device, Mesh.StaticVertex, Mesh.box.vertices, Mesh.box.indices, &.{.{
        .index_start = 0,
        .index_count = @intCast(Mesh.box.indices.len),
        .texture = .blank,
    }});
}
