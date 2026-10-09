const Image = @This();

const std = @import("std");
const vk = @import("vulkan");
const GpuMemory = @import("GpuMemory.zig");
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");

vk_image: vk.Image,
vk_imageview: vk.ImageView,
range: GpuMemory.Range,
extent: vk.Extent3D,
format: vk.Format,
mip_levels: u32,

pub const Kind = enum(u8) {
    @"2d" = 0,
    @"3d" = 1,
    cube_map = 2,
};

pub fn init(
    heap: *GpuMemory,
    device: Device,
    format: vk.Format,
    extent: vk.Extent3D,
    kind: Kind,
    usage: vk.ImageUsageFlags,
    aspect: vk.ImageAspectFlags,
    mip_mapped: bool,
) !Image {
    const mip_levels: u32 = if (mip_mapped) std.math.log2_int(u32, @max(extent.width, extent.height)) + 1 else 1;
    const layer_count: u32 = if (kind == .cube_map) 6 else 1;
    const image = try device.proxy.createImage(&.{
        .flags = .{ .cube_compatible_bit = kind == .cube_map },
        .image_type = if (kind == .@"3d") .@"3d" else .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = mip_levels,
        .array_layers = layer_count,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer device.proxy.destroyImage(image, null);
    const range = try heap.alloc(device.proxy.getImageMemoryRequirements(image));
    errdefer heap.free(range);
    try device.proxy.bindImageMemory(image, heap.memory, range.offset);

    const image_view = try device.proxy.createImageView(&.{
        .image = image,
        .view_type = switch (kind) {
            .@"2d" => .@"2d",
            .@"3d" => .@"3d",
            .cube_map => .cube,
        },
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = mip_levels,
            .base_array_layer = 0,
            .layer_count = layer_count,
        },
    }, null);

    return .{
        .vk_image = image,
        .vk_imageview = image_view,
        .range = range,
        .extent = extent,
        .format = format,
        .mip_levels = mip_levels,
    };
}

pub fn deinit(self: *Image, heap: *GpuMemory, device: Device) void {
    device.proxy.destroyImageView(self.vk_imageview, null);
    device.proxy.destroyImage(self.vk_image, null);
    heap.free(self.range);
}

pub fn recordUpload(self: *Image, device: Device, cmd: vk.CommandBuffer, upload_buffer: Buffer, layer: u32, buffer_offset: u64) void {
    var image_barrier: Barrier = .init(device, cmd, self.vk_image, .{ .color_bit = true });
    image_barrier.base_array_layer = layer;
    image_barrier.level_count = self.mip_levels;
    image_barrier.transition(.transfer_dst_optimal, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true });

    const region = [_]vk.BufferImageCopy{.{
        .buffer_offset = buffer_offset,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = layer, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = self.extent,
    }};
    device.proxy.cmdCopyBufferToImage(cmd, upload_buffer.buffer, self.vk_image, .transfer_dst_optimal, &region);

    if (self.mip_levels > 1) {
        self.generateMipmaps(device, cmd, layer);
    } else {
        image_barrier.transition(.shader_read_only_optimal, .{ .fragment_shader_bit = true, .vertex_shader_bit = true }, .{ .shader_read_bit = true });
    }
}

fn generateMipmaps(self: *Image, device: Device, cmd: vk.CommandBuffer, layer: u32) void {
    var width: i32 = @intCast(self.extent.width);
    var height: i32 = @intCast(self.extent.height);
    for (0..self.mip_levels - 1) |mip| {
        var source: Barrier = .init(device, cmd, self.vk_image, .{ .color_bit = true });
        source.base_array_layer = layer;
        source.base_mip_level = @intCast(mip);
        source.old_layout = .transfer_dst_optimal;
        source.src_stage = .{ .all_transfer_bit = true };
        source.src_access = .{ .transfer_write_bit = true };
        source.transition(.transfer_src_optimal, .{ .all_transfer_bit = true }, .{ .transfer_read_bit = true });

        const half_width = @max(1, @divTrunc(width, 2));
        const half_height = @max(1, @divTrunc(height, 2));
        const region = [_]vk.ImageBlit2{.{
            .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = @intCast(mip), .base_array_layer = layer, .layer_count = 1 },
            .src_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = width, .y = height, .z = 1 } },
            .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = @intCast(mip + 1), .base_array_layer = layer, .layer_count = 1 },
            .dst_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = half_width, .y = half_height, .z = 1 } },
        }};
        device.proxy.cmdBlitImage2(cmd, &.{
            .src_image = self.vk_image,
            .src_image_layout = .transfer_src_optimal,
            .dst_image = self.vk_image,
            .dst_image_layout = .transfer_dst_optimal,
            .region_count = region.len,
            .p_regions = &region,
            .filter = .linear,
        });
        source.transition(.shader_read_only_optimal, .{ .fragment_shader_bit = true, .vertex_shader_bit = true }, .{ .shader_read_bit = true });
        width = half_width;
        height = half_height;
    }
    var last: Barrier = .init(device, cmd, self.vk_image, .{ .color_bit = true });
    last.base_array_layer = layer;
    last.base_mip_level = self.mip_levels - 1;
    last.old_layout = .transfer_dst_optimal;
    last.src_stage = .{ .all_transfer_bit = true };
    last.src_access = .{ .transfer_write_bit = true };
    last.transition(.shader_read_only_optimal, .{ .fragment_shader_bit = true, .vertex_shader_bit = true }, .{ .shader_read_bit = true });
}

pub fn copyOntoImage(self: Image, device: Device, cmd: vk.CommandBuffer, dest_image: vk.Image, dest_extent: vk.Extent3D) void {
    const region = [_]vk.ImageBlit2{.{
        .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .src_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(self.extent.width), .y = @intCast(self.extent.height), .z = 1 } },
        .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .dst_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(dest_extent.width), .y = @intCast(dest_extent.height), .z = 1 } },
    }};
    device.proxy.cmdBlitImage2(cmd, &.{
        .src_image = self.vk_image,
        .src_image_layout = .transfer_src_optimal,
        .dst_image = dest_image,
        .dst_image_layout = .transfer_dst_optimal,
        .region_count = region.len,
        .p_regions = &region,
        .filter = .linear,
    });
}

pub const Barrier = struct {
    device: Device,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    aspect_mask: vk.ImageAspectFlags,
    old_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    base_array_layer: u32,
    base_mip_level: u32,
    level_count: u32,

    pub fn init(device: Device, cmd: vk.CommandBuffer, image: vk.Image, aspect_mask: vk.ImageAspectFlags) Barrier {
        return .{
            .device = device,
            .cmd = cmd,
            .image = image,
            .aspect_mask = aspect_mask,
            .old_layout = .undefined,
            .src_stage = .{ .top_of_pipe_bit = true },
            .src_access = .{},
            .base_array_layer = 0,
            .base_mip_level = 0,
            .level_count = 1,
        };
    }

    pub fn transition(self: *Barrier, layout: vk.ImageLayout, stage: vk.PipelineStageFlags2, access: vk.AccessFlags2) void {
        const barrier = [_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = self.src_stage,
            .src_access_mask = self.src_access,
            .dst_stage_mask = stage,
            .dst_access_mask = access,
            .old_layout = self.old_layout,
            .new_layout = layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = self.aspect_mask,
                .base_mip_level = self.base_mip_level,
                .level_count = self.level_count,
                .base_array_layer = self.base_array_layer,
                .layer_count = 1,
            },
        }};
        self.device.proxy.cmdPipelineBarrier2(self.cmd, &.{
            .image_memory_barrier_count = barrier.len,
            .p_image_memory_barriers = &barrier,
        });
        self.old_layout = layout;
        self.src_stage = stage;
        self.src_access = access;
    }
};
