const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const descriptor = @import("desrciptor.zig");
const pipeline = @import("pipeline.zig");
const Mesh = @import("Mesh.zig");
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

pub const DescriptorLayoutKind = enum { scene, material, ui };
pub const PipelineLayoutKind = enum { world, ui };

set_size: c.VkDeviceSize,
combined_image_sampler_descriptor_size: usize,
meshes: std.StringArrayHashMapUnmanaged(Mesh),
materials: std.StringArrayHashMapUnmanaged(Material),
samplers: std.ArrayList(c.VkSampler),
images: std.ArrayList(Image),
descriptor_layouts: std.EnumArray(DescriptorLayoutKind, descriptor.Layout),
pipeline_layouts: std.EnumArray(PipelineLayoutKind, pipeline.Layout),
ui_texture_buffer: Buffer,
font: *Font,

pub fn init(gpa: std.mem.Allocator, vma: Vma, physical_device: PhysicalDevice, device: Device, asset_server: *AssetServer) !@This() {
    const meshes: std.StringArrayHashMapUnmanaged(Mesh) = .empty;
    var materials: std.StringArrayHashMapUnmanaged(Material) = .empty;
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

    const descriptor_layouts: std.EnumArray(DescriptorLayoutKind, descriptor.Layout) = .init(.{
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

    const pipeline_layouts: std.EnumArray(PipelineLayoutKind, pipeline.Layout) = .init(.{
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
    var green_color: nz.color.Rgba(u8) = .{ .r = 155, .g = 255, .b = 0, .a = 255 };
    try default_texture.uploadDataToImage(vma, device, &green_color, 4, 0);
    try images.append(gpa, default_texture);
    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
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
    try materials.put(gpa, default_material.name, default_material);

    var self: @This() = .{
        .combined_image_sampler_descriptor_size = db_props.combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .meshes = meshes,
        .materials = materials,
        .samplers = samplers,
        .images = images,
        .descriptor_layouts = descriptor_layouts,
        .pipeline_layouts = pipeline_layouts,
        .ui_texture_buffer = ui_texture_buffer,
        .font = try .init(gpa, vma, device, "fonts/Roboto-Regular.ttf", asset_server),
    };
    try self.loadUiTextures(gpa, vma, device);
    return self;
}

fn loadUiTextures(self: *@This(), gpa: std.mem.Allocator, vma: Vma, device: Device) !void {
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

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    {
        var it = self.materials.iterator();
        while (it.next()) |pair| {
            pair.value_ptr.deinit(gpa, vma);
        }
        self.materials.deinit(gpa);
    }

    for (self.images.items) |*image| {
        image.deinit(vma, device);
    }
    self.images.deinit(gpa);

    for (self.samplers.items) |sampler| {
        c.vkDestroySampler(device.handle, sampler, null);
    }
    self.samplers.deinit(gpa);

    for (self.meshes.values()) |*mesh| {
        mesh.deinit(gpa, vma);
    }
    self.meshes.deinit(gpa);

    for (self.descriptor_layouts.values) |layout| {
        layout.deinit(device);
    }
    for (&self.pipeline_layouts.values) |*layout| {
        layout.deinit(device);
    }
    self.ui_texture_buffer.deinit(vma);
    self.font.deinit(gpa, vma, device);
}

pub fn getMeshPtr(self: *@This(), name_id: ?[]const u8) !*Mesh {
    if (name_id) |name| {
        // std.log.debug("got mesh: {s}", .{name});
        if (self.meshes.getPtr(name)) |mesh| return mesh;
    } else {
        std.log.debug("mesh: NULL", .{});
    }
    if (self.meshes.getPtr(default_mesh_name)) |default_mesh| return default_mesh else {
        return error.NoDefaultMeshFound;
    }
}
pub fn getMaterialPtr(self: *@This(), name_id: ?[]const u8) !*Material {
    if (name_id) |name| if (self.materials.getPtr(name)) |material| return material;
    if (self.materials.getPtr(default_material_name)) |default_material| return default_material else {
        return error.NoDefaultMaterialFound;
    }
}
