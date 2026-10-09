const Surface = @This();

const std = @import("std");
const builtin = @import("builtin");
const Window = @import("Window");
const Instance = @import("Instance.zig");
const device = @import("device.zig");
const vk = @import("vulkan");

handle: vk.SurfaceKHR,

const debug_instance_extensions = if (builtin.mode == .Debug)
    [_][*:0]const u8{vk.extensions.ext_debug_utils.name}
else
    [_][*:0]const u8{};

pub fn instanceExtensions(window: *const Window) []const [*:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &(debug_instance_extensions ++ [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_win32_surface",
        }),
        .linux, .freebsd, .netbsd, .openbsd => switch (window.inner) {
            .wayland => &(debug_instance_extensions ++ [_][*:0]const u8{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_display.name,
                "VK_KHR_wayland_surface",
            }),
            .x11 => &(debug_instance_extensions ++ [_][*:0]const u8{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_display.name,
                "VK_KHR_xlib_surface",
                "VK_KHR_xcb_surface",
            }),
        },
        else => &.{},
    };
}

pub fn create(instance: Instance, window: *Window) !Surface {
    const handle: vk.SurfaceKHR = switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd => switch (window.inner) {
            .wayland => |wayland| try instance.proxy.createWaylandSurfaceKHR(&.{
                .display = @ptrCast(wayland.display),
                .surface = @ptrCast(wayland.surface),
            }, null),
            .x11 => |x11| try instance.proxy.createXlibSurfaceKHR(&.{
                .dpy = @ptrCast(x11.display),
                .window = x11.window.id,
            }, null),
        },
        .windows => try instance.proxy.createWin32SurfaceKHR(&.{
            .hinstance = @ptrCast(window.inner.hinstance),
            .hwnd = @ptrCast(window.inner.hwnd),
        }, null),
        else => return error.UnsupportedPlatform,
    };
    return .{ .handle = handle };
}

pub fn deinit(self: Surface, instance: Instance) void {
    instance.proxy.destroySurfaceKHR(self.handle, null);
}

pub fn getFormat(self: Surface, gpa: std.mem.Allocator, instance: Instance, physical_device: device.Physical) !vk.SurfaceFormatKHR {
    const formats = try instance.proxy.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device.handle, self.handle, gpa);
    defer gpa.free(formats);
    for (formats) |format| {
        if (format.format == .r8g8b8a8_unorm or format.format == .b8g8r8a8_unorm) return format;
    }
    return formats[0];
}

pub fn getExtent(self: Surface, instance: Instance, physical_device: device.Physical, width: u32, height: u32) !vk.Extent2D {
    const capabilities = try instance.proxy.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, self.handle);
    if (capabilities.current_extent.width != std.math.maxInt(u32) and capabilities.current_extent.height != std.math.maxInt(u32))
        return capabilities.current_extent;
    return .{
        .width = @max(capabilities.min_image_extent.width, @min(capabilities.max_image_extent.width, width)),
        .height = @max(capabilities.min_image_extent.height, @min(capabilities.max_image_extent.height, height)),
    };
}
