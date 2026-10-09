const Swapchain = @This();

const std = @import("std");
const vk = @import("vulkan");
const GpuMemory = @import("GpuMemory.zig");
const Instance = @import("Instance.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const Surface = @import("Surface.zig");
const Image = @import("Image.zig");

pub const max_images = 16;

swapchain: vk.SwapchainKHR,
present_mode: vk.PresentModeKHR,
images: [max_images]vk.Image,
render_semaphores: [max_images]vk.Semaphore,
image_count: u32,
format: vk.Format,
extent: vk.Extent3D,
draw_image: Image,
depth_image: Image,
mask_image: Image,

pub const draw_format: vk.Format = .r16g16b16a16_sfloat;
pub const depth_format: vk.Format = .d32_sfloat;
pub const mask_format: vk.Format = .r8_unorm;

pub fn init(
    gpa: std.mem.Allocator,
    heap: *GpuMemory,
    instance: Instance,
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    width: u32,
    height: u32,
) !Swapchain {
    var self: Swapchain = .{
        .swapchain = .null_handle,
        .present_mode = try getPresentMode(gpa, instance, physical_device, surface),
        .images = undefined,
        .render_semaphores = undefined,
        .image_count = 0,
        .format = undefined,
        .extent = undefined,
        .draw_image = undefined,
        .depth_image = undefined,
        .mask_image = undefined,
    };
    try self.build(gpa, heap, instance, physical_device, device, surface, width, height);
    return self;
}

pub fn deinit(self: *Swapchain, heap: *GpuMemory, device: Device) void {
    self.destroy(heap, device);
}

pub fn recreate(
    self: *Swapchain,
    gpa: std.mem.Allocator,
    heap: *GpuMemory,
    instance: Instance,
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    width: u32,
    height: u32,
) !void {
    try device.proxy.deviceWaitIdle();
    self.destroy(heap, device);
    try self.build(gpa, heap, instance, physical_device, device, surface, width, height);
}

fn destroy(self: *Swapchain, heap: *GpuMemory, device: Device) void {
    self.draw_image.deinit(heap, device);
    self.depth_image.deinit(heap, device);
    self.mask_image.deinit(heap, device);
    for (self.render_semaphores[0..self.image_count]) |semaphore| device.proxy.destroySemaphore(
        semaphore,
        null,
    );
    device.proxy.destroySwapchainKHR(self.swapchain, null);
}

fn build(
    self: *Swapchain,
    gpa: std.mem.Allocator,
    heap: *GpuMemory,
    instance: Instance,
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    width: u32,
    height: u32,
) !void {
    const surface_format = try surface.getFormat(gpa, instance, physical_device);
    const capabilities = try instance.proxy.getPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device.handle,
        surface.handle,
    );
    const actual_extent = try surface.getExtent(instance, physical_device, width, height);

    self.swapchain = try device.proxy.createSwapchainKHR(&.{
        .surface = surface.handle,
        .min_image_count = capabilities.min_image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .transfer_dst_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = self.present_mode,
        .clipped = .true,
    }, null);
    self.format = surface_format.format;
    self.extent = .{ .width = actual_extent.width, .height = actual_extent.height, .depth = 1 };

    var image_count: u32 = undefined;
    _ = try device.proxy.getSwapchainImagesKHR(self.swapchain, &image_count, null);
    std.debug.assert(image_count <= max_images);
    _ = try device.proxy.getSwapchainImagesKHR(self.swapchain, &image_count, &self.images);
    self.image_count = image_count;
    for (self.render_semaphores[0..image_count]) |*semaphore| semaphore.* = try device.proxy.createSemaphore(
        &.{},
        null,
    );

    self.draw_image = try .init(heap, device, draw_format, self.extent, .@"2d", .{
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
        .storage_bit = true,
        .color_attachment_bit = true,
    }, .{ .color_bit = true }, false);
    self.depth_image = try .init(
        heap,
        device,
        depth_format,
        self.extent,
        .@"2d",
        .{ .depth_stencil_attachment_bit = true },
        .{ .depth_bit = true },
        false,
    );
    self.mask_image = try .init(
        heap,
        device,
        mask_format,
        self.extent,
        .@"2d",
        .{ .color_attachment_bit = true, .sampled_bit = true },
        .{ .color_bit = true },
        false,
    );

    const cmd = try device.beginImmediateCommand();
    var depth_image_barrier: Image.Barrier = .init(
        device,
        cmd,
        self.depth_image.vk_image,
        .{ .depth_bit = true },
    );
    depth_image_barrier.transition(
        .depth_attachment_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
    );
    try device.endImmediateCommand(cmd);
}

fn getPresentMode(
    gpa: std.mem.Allocator,
    instance: Instance,
    physical_device: PhysicalDevice,
    surface: Surface,
) !vk.PresentModeKHR {
    const present_modes = try instance.proxy.getPhysicalDeviceSurfacePresentModesAllocKHR(
        physical_device.handle,
        surface.handle,
        gpa,
    );
    defer gpa.free(present_modes);
    var found: vk.PresentModeKHR = .fifo_khr;
    for (present_modes) |mode| {
        if (mode == .mailbox_khr) return mode;
        if (mode == .immediate_khr) {
            found = mode;
        } else if (mode == .fifo_relaxed_khr and found == .fifo_khr) {
            found = mode;
        }
    }
    return found;
}
