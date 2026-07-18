const Image = @This();

const std = @import("std");
const c = @import("vulkan");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const check = @import("utils.zig").check;
const stb_image = @import("stb_image");

vk_image: c.VkImage = undefined,
vk_imageview: c.VkImageView = undefined,
vma_allocation: Vma.Allocation = undefined,
extent: c.VkExtent3D = undefined,
format: c.VkFormat = undefined,
mip_mapped: bool = undefined,

const Kind = enum(u8) {
    @"2d" = 0,
    @"3d" = 1,
    cube_map = 2,
};

pub const Handle = enum(u32) {
    blank = 0,
    _,

    pub fn index(self: Handle) usize {
        return @intFromEnum(self);
    }
};

pub fn init(
    vma: Vma,
    device: Device,
    format: c.VkFormat,
    extent: c.VkExtent3D,
    kind: Kind,
    usages_flags: c.VkImageUsageFlags,
    view_mask: c.VkImageAspectFlags,
    mip_mapped: bool,
) !Image {
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .extent = extent,
        .format = format,
        .mipLevels = 1,
        .imageType = switch (kind) {
            .@"2d" => c.VK_IMAGE_TYPE_2D,
            .@"3d" => c.VK_IMAGE_TYPE_3D,
            .cube_map => c.VK_IMAGE_TYPE_2D,
        },
        .arrayLayers = if (kind == .cube_map) 6 else 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = usages_flags,
        .flags = if (kind == .cube_map) c.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT else 0,
    };

    const max: f32 = @floatFromInt(@max(extent.width, extent.height));
    if (mip_mapped) {
        image_info.mipLevels = @as(u32, @intFromFloat(@floor(@log2(max)))) + 1;
    }

    var vma_alloc_info: Vma.c.VmaAllocationCreateInfo = .{
        .usage = Vma.c.VMA_MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    };

    var image: c.VkImage = undefined;
    var vma_image_allocation: Vma.Allocation = undefined;
    _ = Vma.c.vmaCreateImage(
        vma.handle,
        @ptrCast(&image_info),
        &vma_alloc_info,
        @ptrCast(&image),
        &vma_image_allocation,
        null,
    );

    var image_view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = switch (kind) {
            .@"2d" => c.VK_IMAGE_VIEW_TYPE_2D,
            .@"3d" => c.VK_IMAGE_VIEW_TYPE_3D,
            .cube_map => c.VK_IMAGE_VIEW_TYPE_CUBE,
        },
        .image = image,
        .format = format,
        .subresourceRange = .{
            .baseMipLevel = 0,
            .levelCount = image_info.mipLevels,
            .baseArrayLayer = 0,
            .layerCount = if (kind == .cube_map) 6 else 1,
            .aspectMask = view_mask,
        },
    };

    var image_view: c.VkImageView = undefined;
    try check(c.vkCreateImageView(device.handle, &image_view_info, null, &image_view));

    return .{
        .format = format,
        .extent = extent,
        .vk_image = image,
        .vk_imageview = image_view,
        .vma_allocation = vma_image_allocation,
        .mip_mapped = mip_mapped,
    };
}

pub fn deinit(self: *Image, vulkan_mem_alloc: Vma, device: Device) void {
    c.vkDestroyImageView(device.handle, self.vk_imageview, null);
    Vma.c.vmaDestroyImage(vulkan_mem_alloc.handle, @ptrCast(self.vk_image), self.vma_allocation);
}

pub fn uploadDataToImage(self: *Image, vma: Vma, device: Device, data: anytype, bytes_per_pixel: u32, layer: u32) !void {
    var upload_buffers: std.ArrayList(Buffer) = .empty;
    defer {
        for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(vma);
        upload_buffers.deinit(std.heap.page_allocator);
    }

    const cmd = try device.beginImmediateCommand();
    try self.recordUploadDataToImage(
        std.heap.page_allocator,
        vma,
        device,
        cmd,
        data,
        layer,
        bytes_per_pixel,
        &upload_buffers,
    );
    try device.endImmediateCommand(cmd);
}

pub fn recordUploadDataToImage(
    self: *Image,
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    cmd: c.VkCommandBuffer,
    data: anytype,
    layer: u32,
    bytes_per_pixel: u32,
    upload_buffers: *std.ArrayList(Buffer),
) !void {
    const data_size: u32 = self.extent.depth * self.extent.width * self.extent.height * bytes_per_pixel;

    var upload_buffer: Buffer = try .init(
        device,
        vma,
        u8,
        data_size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
    );
    errdefer upload_buffer.deinit(vma);

    @memcpy(
        @as([*]u8, @ptrCast(upload_buffer.info.pMappedData))[0..@intCast(data_size)],
        @as([*]u8, @ptrCast(data))[0..@intCast(data_size)],
    );

    var image_barrier: Barrier = .init(cmd, self.vk_image, c.VK_IMAGE_ASPECT_COLOR_BIT);
    image_barrier.base_array_layer = layer;
    image_barrier.transition(
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_ACCESS_MEMORY_WRITE_BIT,
    );

    var copy_region: c.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = layer,
            .layerCount = 1,
        },
        .imageExtent = self.extent,
    };

    c.vkCmdCopyBufferToImage(
        cmd,
        upload_buffer.buffer,
        self.vk_image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &copy_region,
    );

    if (self.mip_mapped) {
        generateMipmaps(self, cmd, self.extent);
    } else {
        image_barrier.transition(
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            0,
            0,
        );
    }

    try upload_buffers.append(gpa, upload_buffer);
}

fn generateMipmaps(self: *Image, cmd_buffer: c.VkCommandBuffer, image_size: c.VkExtent3D) void {
    var size = image_size;
    const mip_levels: usize = @as(usize, @intFromFloat(@floor(@log2(@as(f32, @floatFromInt(@max(size.width, size.height))))))) + 1;

    var mip_levels_barrier: Barrier = .init(cmd_buffer, self.vk_image, c.VK_IMAGE_ASPECT_COLOR_BIT);
    mip_levels_barrier.transitionMipLevel(
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        @intCast(mip_levels),
        0,
        1,
    );

    for (0..mip_levels) |mip| {
        const half_size: c.VkExtent3D = .{
            .height = size.height / 2,
            .width = size.width / 2,
        };
        mip_levels_barrier.old_layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        mip_levels_barrier.src_access = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
        mip_levels_barrier.src_stage = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
        mip_levels_barrier.transitionMipLevel(
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            c.VK_ACCESS_2_MEMORY_READ_BIT,
            1,
            @intCast(mip),
            c.VK_REMAINING_ARRAY_LAYERS,
        );
        if (mip >= mip_levels - 1) continue;

        var blit_info: c.VkBlitImageInfo2 = .{
            .sType = c.VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2,
            .pNext = null,
            .pRegions = &.{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_BLIT_2,
                .pNext = null,
                .srcOffsets = .{
                    .{},
                    .{
                        .x = @intCast(size.width),
                        .y = @intCast(size.height),
                        .z = 1,
                    },
                },
                .dstOffsets = .{
                    .{},
                    .{
                        .x = @intCast(half_size.width),
                        .y = @intCast(half_size.height),
                        .z = 1,
                    },
                },
                .srcSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                    .mipLevel = @intCast(mip),
                },
                .dstSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                    .mipLevel = @intCast(mip + 1),
                },
            },
            .dstImage = self.vk_image,
            .dstImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcImage = self.vk_image,
            .srcImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .filter = c.VK_FILTER_LINEAR,
            .regionCount = 1,
        };

        c.vkCmdBlitImage2(cmd_buffer, &blit_info);

        size = half_size;
    }
    mip_levels_barrier.transitionMipLevel(
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        @intCast(mip_levels),
        0,
        1,
    );
}

pub fn copyOntoImage(self: Image, cmd: c.VkCommandBuffer, dest_image: Image) void {
    var blit_region: c.VkImageBlit2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_BLIT_2,
        .pNext = null,
        .srcOffsets = .{ .{}, .{
            .x = @intCast(self.extent.width),
            .y = @intCast(self.extent.height),
            .z = 1,
        } },
        .dstOffsets = .{ .{}, .{
            .x = @intCast(dest_image.extent.width),
            .y = @intCast(dest_image.extent.height),
            .z = 1,
        } },
        .srcSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .mipLevel = 0,
        },
        .dstSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .mipLevel = 0,
        },
    };

    var blit_info: c.VkBlitImageInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2,
        .pNext = null,
        .dstImage = dest_image.vk_image,
        .dstImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcImage = self.vk_image,
        .srcImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .filter = c.VK_FILTER_LINEAR,
        .regionCount = 1,
        .pRegions = &blit_region,
    };

    c.vkCmdBlitImage2(cmd, &blit_info);
}

pub const Barrier = struct {
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    aspect_mask: c.VkImageAspectFlags,

    old_layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    src_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    src_access: c.VkAccessFlags = 0,

    base_array_layer: u32 = 0,

    pub fn init(cmd: c.VkCommandBuffer, image: c.VkImage, aspect_mask: c.VkImageAspectFlags) Barrier {
        return .{
            .cmd = cmd,
            .image = image,
            .aspect_mask = aspect_mask,
        };
    }

    pub fn transition(self: *Barrier, layout: c.VkImageLayout, stage: c.VkPipelineStageFlags, access: c.VkAccessFlags) void {
        var new: c.VkImageMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            // .srcStageMask = src_stage,
            .srcAccessMask = self.src_access,
            // .dstStageMask = dst_stage,
            .dstAccessMask = access,
            .oldLayout = self.old_layout,
            .newLayout = layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = .{
                .aspectMask = self.aspect_mask,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = self.base_array_layer,
                .layerCount = 1,
            },
        };
        c.vkCmdPipelineBarrier(self.cmd, self.src_stage, stage, 0, 0, null, 0, null, 1, &new);
        self.*.old_layout = layout;
        self.*.src_stage = stage;
        self.*.src_access = access;
    }

    pub fn transitionMipLevel(
        self: *Barrier,
        new_layout: c.VkImageLayout,
        dst_stage: c.VkPipelineStageFlags,
        dst_access: c.VkAccessFlags,
        level_count: u32,
        base_mip_level: u32,
        layer_count: u32,
    ) void {
        var new: c.VkImageMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = self.src_stage,

            .srcAccessMask = self.src_access,
            .dstStageMask = dst_stage,
            .dstAccessMask = dst_access,
            .oldLayout = self.old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = .{
                .aspectMask = self.aspect_mask,
                .baseMipLevel = base_mip_level,
                .levelCount = level_count,
                .baseArrayLayer = 0,
                .layerCount = layer_count,
            },
        };
        var dep: c.VkDependencyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .pNext = null,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &new,
        };
        c.vkCmdPipelineBarrier2(self.cmd, &dep);
        self.*.old_layout = new_layout;
        self.*.src_stage = dst_stage;
        self.*.src_access = dst_access;
    }
};

pub const DecodeError = error{
    DataNotSupported,
    FailedToLoadGLTFImage,
    LoadingStbi,
    MissingBufferViews,
};

pub const Decoded = struct {
    pixels: [*c]stb_image.stbi_uc = null,
    width: i32 = 0,
    height: i32 = 0,
    nr_channel: i32 = 0,
    err: ?DecodeError = null,

    pub fn deinit(self: *Decoded) void {
        if (self.pixels != null) stb_image.stbi_image_free(self.pixels);
        self.* = .{};
    }
};

pub const DecodeTask = struct {
    bytes: ?[]const u8 = null,
    uri: ?[:0]const u8 = null,
    result: *Decoded,
};

pub fn decodeImages(gpa: std.mem.Allocator, tasks: []DecodeTask) !void {
    if (tasks.len == 0) return;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(tasks.len, @max(@as(usize, 1), cpu_count));
    if (worker_count == 1) {
        decodeImageWorker(tasks, 0, 1);
        return;
    }

    // TODO: Replace per-model thread spawning with a persistent asset thread pool.
    var threads = try gpa.alloc(std.Thread, worker_count);
    defer gpa.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (threads[0..spawned]) |thread| thread.join();
    }

    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, decodeImageWorker, .{ tasks, spawned, worker_count });
    }
    for (threads) |thread| thread.join();
}

fn decodeImageWorker(tasks: []DecodeTask, worker_index: usize, worker_count: usize) void {
    var image_index = worker_index;
    while (image_index < tasks.len) : (image_index += worker_count) {
        decodeImageTask(&tasks[image_index]);
    }
}

fn decodeImageTask(task: *DecodeTask) void {
    var width: i32 = 0;
    var height: i32 = 0;
    var nr_channel: i32 = 0;

    if (task.uri) |uri| {
        task.result.pixels = stb_image.stbi_load(uri, &width, &height, &nr_channel, 4);
    } else if (task.bytes) |bytes| {
        task.result.pixels = stb_image.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &nr_channel, 4);
    } else {
        task.result.err = error.FailedToLoadGLTFImage;
        return;
    }

    if (task.result.pixels == null) {
        task.result.err = error.LoadingStbi;
        return;
    }

    task.result.width = width;
    task.result.height = height;
    task.result.nr_channel = nr_channel;
}
