const TextureTable = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("device.zig").Logical;
const contract = @import("renderer_contract");

pub const max_textures = 256;
pub const max_samplers = 16;

set: vk.DescriptorSet,
skybox_set: vk.DescriptorSet,
taken: [max_textures]bool,
samplers: [max_samplers]vk.Sampler,
sampler_count: u32,
empty_view: vk.ImageView,
empty_sampler: vk.Sampler,

pub fn init(
    device: Device,
    pool: vk.DescriptorPool,
    textures_layout: vk.DescriptorSetLayout,
    material_layout: vk.DescriptorSetLayout,
) !TextureTable {
    const layouts = [_]vk.DescriptorSetLayout{ textures_layout, material_layout };
    var sets: [2]vk.DescriptorSet = undefined;
    try device.proxy.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = layouts.len,
        .p_set_layouts = &layouts,
    }, &sets);

    var self: TextureTable = .{
        .set = sets[0],
        .skybox_set = sets[1],
        .taken = taken: {
            var named: [max_textures]bool = @splat(false);
            for (0..@typeInfo(contract.TextureHandle).@"enum".fields.len) |slot| named[slot] = true;
            break :taken named;
        },
        .samplers = undefined,
        .sampler_count = 0,
        .empty_view = .null_handle,
        .empty_sampler = .null_handle,
    };
    _ = try self.addSampler(device, .{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
    });
    return self;
}

pub fn deinit(self: *TextureTable, device: Device) void {
    for (self.samplers[0..self.sampler_count]) |sampler| device.proxy.destroySampler(sampler, null);
}

pub fn defaultSampler(self: *const TextureTable) vk.Sampler {
    return self.samplers[0];
}

pub fn registerEmpty(
    self: *TextureTable,
    device: Device,
    view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    self.empty_view = view;
    self.empty_sampler = sampler;
    for (0..max_textures) |slot| self.write(device, @enumFromInt(slot), view, sampler);
}

pub fn alloc(self: *TextureTable) contract.TextureHandle {
    const slot = std.mem.indexOfScalar(bool, &self.taken, false).?;
    self.taken[slot] = true;
    return @enumFromInt(slot);
}

pub fn free(self: *TextureTable, device: Device, texture: contract.TextureHandle) void {
    device.proxy.deviceWaitIdle() catch {};
    self.write(device, texture, self.empty_view, self.empty_sampler);
    self.taken[@intFromEnum(texture)] = false;
}

pub fn addSampler(self: *TextureTable, device: Device, info: vk.SamplerCreateInfo) !vk.Sampler {
    std.debug.assert(self.sampler_count < max_samplers);
    const sampler = try device.proxy.createSampler(&info, null);
    self.samplers[self.sampler_count] = sampler;
    self.sampler_count += 1;
    return sampler;
}

pub fn addFilterSampler(
    self: *TextureTable,
    device: Device,
    mag_linear: bool,
    min_linear: bool,
) !vk.Sampler {
    return self.addSampler(device, .{
        .mag_filter = if (mag_linear) .linear else .nearest,
        .min_filter = if (min_linear) .linear else .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = vk.LOD_CLAMP_NONE,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
    });
}

pub fn write(
    self: *TextureTable,
    device: Device,
    texture: contract.TextureHandle,
    view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    writeCombinedSampler(device, self.set, 0, @intFromEnum(texture), view, sampler);
}

pub fn writeSkybox(
    self: *TextureTable,
    device: Device,
    view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    device.proxy.deviceWaitIdle() catch {};
    writeCombinedSampler(device, self.skybox_set, 0, 0, view, sampler);
}

pub fn writeCombinedSampler(
    device: Device,
    set: vk.DescriptorSet,
    binding: u32,
    array_element: u32,
    view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    const image_info = [_]vk.DescriptorImageInfo{.{
        .sampler = sampler,
        .image_view = view,
        .image_layout = .shader_read_only_optimal,
    }};
    const descriptor_write = [_]vk.WriteDescriptorSet{.{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = array_element,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &image_info,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }};
    device.proxy.updateDescriptorSets(&descriptor_write, null);
}

pub fn writeUniformBuffer(
    device: Device,
    set: vk.DescriptorSet,
    binding: u32,
    buffer: vk.Buffer,
) void {
    const buffer_info = [_]vk.DescriptorBufferInfo{.{
        .buffer = buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    }};
    const descriptor_write = [_]vk.WriteDescriptorSet{.{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .p_image_info = undefined,
        .p_buffer_info = &buffer_info,
        .p_texel_buffer_view = undefined,
    }};
    device.proxy.updateDescriptorSets(&descriptor_write, null);
}
