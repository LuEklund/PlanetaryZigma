const Surface = @This();

const std = @import("std");
const builtin = @import("builtin");
const Window = @import("Window");
const Instance = @import("Instance.zig");
const device = @import("device.zig");
const c = @import("vulkan");
const check = @import("utils.zig").check;

handle: c.VkSurfaceKHR,

const debug_instance_extensions = if (builtin.mode == .Debug)
    [_][*:0]const u8{c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME}
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
                c.VK_KHR_SURFACE_EXTENSION_NAME,
                c.VK_KHR_DISPLAY_EXTENSION_NAME,
                "VK_KHR_wayland_surface",
            }),
            .x11 => &(debug_instance_extensions ++ [_][*:0]const u8{
                c.VK_KHR_SURFACE_EXTENSION_NAME,
                c.VK_KHR_DISPLAY_EXTENSION_NAME,
                "VK_KHR_xlib_surface",
                "VK_KHR_xcb_surface",
            }),
        },
        else => &.{},
    };
}

const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    display: *anyopaque,
    surface: *anyopaque,
};

const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    dpy: *anyopaque,
    window: c_ulong,
};

const VkWin32SurfaceCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

fn surfaceProc(comptime CreateInfo: type, instance: Instance, name: [*:0]const u8) !*const fn (c.VkInstance, *const CreateInfo, ?*const anyopaque, *c.VkSurfaceKHR) callconv(.c) c.VkResult {
    return @ptrCast(c.vkGetInstanceProcAddr(instance.handle, name) orelse return error.SurfaceProcMissing);
}

pub fn create(instance: Instance, window: *Window) !Surface {
    var surface: c.VkSurfaceKHR = undefined;
    const result = switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd => switch (window.inner) {
            .wayland => |wayland| blk: {
                const create_surface = try surfaceProc(VkWaylandSurfaceCreateInfoKHR, instance, "vkCreateWaylandSurfaceKHR");
                var create_info: VkWaylandSurfaceCreateInfoKHR = .{ .sType = 1000006000, .pNext = null, .flags = 0, .display = wayland.display, .surface = wayland.surface };
                break :blk create_surface(instance.handle, &create_info, null, &surface);
            },
            .x11 => |x11| blk: {
                const create_surface = try surfaceProc(VkXlibSurfaceCreateInfoKHR, instance, "vkCreateXlibSurfaceKHR");
                var create_info: VkXlibSurfaceCreateInfoKHR = .{ .sType = 1000004000, .pNext = null, .flags = 0, .dpy = x11.display, .window = x11.window.id };
                break :blk create_surface(instance.handle, &create_info, null, &surface);
            },
        },
        .windows => blk: {
            const create_surface = try surfaceProc(VkWin32SurfaceCreateInfoKHR, instance, "vkCreateWin32SurfaceKHR");
            var create_info: VkWin32SurfaceCreateInfoKHR = .{ .sType = 1000009000, .pNext = null, .flags = 0, .hinstance = window.inner.hinstance, .hwnd = window.inner.hwnd };
            break :blk create_surface(instance.handle, &create_info, null, &surface);
        },
        else => return error.UnsupportedPlatform,
    };
    if (result != c.VK_SUCCESS) return error.CreateSurface;
    return .{ .handle = surface };
}

pub fn deinit(self: Surface, instance: Instance) void {
    c.vkDestroySurfaceKHR(instance.handle, self.handle, null);
}

pub fn getFormat(self: Surface, gpa: std.mem.Allocator, physical_device: device.Physical) !c.VkSurfaceFormatKHR {
    var format_count: u32 = 0;
    try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.handle, self.handle, &format_count, null));

    const formats = try gpa.alloc(c.VkSurfaceFormatKHR, format_count);
    defer gpa.free(formats);
    try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.handle, self.handle, &format_count, formats.ptr));

    var chosen_format: c.VkSurfaceFormatKHR = formats[0];
    for (0..format_count) |i| {
        if (formats[i].format == c.VK_FORMAT_R8G8B8A8_UNORM or formats[i].format == c.VK_FORMAT_B8G8R8A8_UNORM) {
            chosen_format = formats[i];
            break;
        }
    }
    return chosen_format;
}

pub fn getExtent(self: Surface, physical_device: device.Physical, width: u32, height: u32) !c.VkExtent2D {
    var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, self.handle, &capabilities));

    const actual_extent: c.VkExtent2D = if (capabilities.currentExtent.width != std.math.maxInt(u32) and
        capabilities.currentExtent.height != std.math.maxInt(u32))
        capabilities.currentExtent
    else
        .{
            .width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, width)),
            .height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, height)),
        };

    return actual_extent;
}
