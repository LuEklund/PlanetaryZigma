const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const descriptor = @import("desrciptor.zig");
const Mesh = @import("Mesh.zig");
const Material = @import("Material.zig");
const Image = @import("Image.zig");

const check = @import("utils.zig").check;

pub const default_material_name: []const u8 = "default";
pub const default_mesh_name: []const u8 = "default";

set_size: c.VkDeviceSize,
combined_image_sampler_descriptor_size: usize,
meshes: std.StringArrayHashMapUnmanaged(Mesh),
materials: std.StringArrayHashMapUnmanaged(Material),
samplers: std.ArrayList(c.VkSampler),
images: std.ArrayList(Image),

pub fn init(gpa: std.mem.Allocator, vma: Vma, physical_device: PhysicalDevice, device: Device, layout: descriptor.Layout) !@This() {
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
    var set_size: c.VkDeviceSize = 0;
    c.vkGetPhysicalDeviceProperties2(physical_device.handle, &prop2);
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, layout.handle, &set_size);

    var default_texture: Image = try .init(vma, device, c.VK_FORMAT_R8G8B8A8_UNORM, .{ .width = 1, .height = 1, .depth = 1 }, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, c.VK_IMAGE_ASPECT_COLOR_BIT, false);
    var green_color: nz.color.Rgba(u8) = .{ .r = 155, .g = 255, .b = 0, .a = 255 };
    try default_texture.uploadDataToImage(vma, device, &green_color, 4);
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

    return .{
        .combined_image_sampler_descriptor_size = db_props.combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .meshes = meshes,
        .materials = materials,
        .samplers = samplers,
        .images = images,
    };
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

    {
        var it = self.meshes.iterator();
        while (it.next()) |pair| {
            pair.value_ptr.deinit(gpa, vma);
        }
        self.meshes.deinit(gpa);
    }
}

pub fn createMesh(self: *@This(), gpa: std.mem.Allocator, mesh: Mesh) !void {
    std.debug.assert(!self.meshes.contains(mesh.name));
    try self.meshes.put(gpa, mesh.name, mesh);
}
pub fn createMaterial(self: *@This(), gpa: std.mem.Allocator, material: Material) !void {
    try self.materials.put(gpa, material.name, material);
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
