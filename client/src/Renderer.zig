const Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const Window = @import("Window");
const AssetServer = @import("AssetServer.zig");
const AnimationInstance = @import("asset/AnimationInstance.zig");
const tracy = @import("ztracy");

inner: Inner,

const Vulkan = @import("Renderer/Vulkan.zig");

pub const Inner = *Vulkan;

pub const FramePacket = @import("Renderer/FramePacket.zig");
pub const TextureTable = @import("Renderer/loader/TextureTable.zig");

pub fn init(gpa: std.mem.Allocator, asset_server: *AssetServer, window: *Window) !Renderer {
    return switch (builtin.os.tag) {
        else => initVulkan(gpa, asset_server, window),
    };
}

pub fn deinit(self: *Renderer, gpa: std.mem.Allocator) void {
    self.inner.deinit(gpa);
    switch (builtin.os.tag) {
        .macos => self.inner.deinit(),
        else => {
            gpa.destroy(self.inner);
        },
    }
}

pub fn update(self: *Renderer, packet: *const FramePacket, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try self.inner.update(packet, instances);
}

const debug_instance_extensions = if (builtin.mode == .Debug)
    [_][*:0]const u8{Vulkan.c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME}
else
    [_][*:0]const u8{};

pub fn resize(self: *Renderer, gpa: std.mem.Allocator, window: *Window) !void {
    try self.inner.resize(gpa, window.size.width, window.size.height);
}

pub fn initVulkan(gpa: std.mem.Allocator, asset_server: *AssetServer, window: *Window) !Renderer {
    const extensions: []const [*:0]const u8 = switch (builtin.os.tag) {
        .windows => &(debug_instance_extensions ++ [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_win32_surface",
        }),
        .macos => &.{
            "VK_KHR_surface",
            "VK_MVK_macos_surface",
        },
        .ios => &.{
            "VK_KHR_surface",
            "VK_MVK_ios_surface",
        },
        .linux, .freebsd, .netbsd, .openbsd => if (builtin.abi == .android) &.{
            "VK_KHR_surface",
            "VK_KHR_android_surface",
        } else switch (window.inner) {
            .wayland => &(debug_instance_extensions ++ [_][*:0]const u8{
                Vulkan.c.VK_KHR_SURFACE_EXTENSION_NAME,
                Vulkan.c.VK_KHR_DISPLAY_EXTENSION_NAME,

                "VK_KHR_surface",
                "VK_KHR_display",
                "VK_KHR_wayland_surface",
            }),
            .x11 => &(debug_instance_extensions ++ [_][*:0]const u8{
                Vulkan.c.VK_KHR_SURFACE_EXTENSION_NAME,
                Vulkan.c.VK_KHR_DISPLAY_EXTENSION_NAME,

                "VK_KHR_surface",
                "VK_KHR_display",
                "VK_KHR_xlib_surface",
                "VK_KHR_xcb_surface",
            }),
        },
        else => &.{},
    };

    const vulkan_renderer: *Vulkan = try .init(gpa, asset_server, .{
        .surface = .{
            .data = window,
            .init = &createVulkanSurface,
        },
        .instance = .{
            .extensions = extensions,
            .layers = if (builtin.mode == .Debug)
                &.{ "VK_LAYER_KHRONOS_validation", "VK_LAYER_KHRONOS_shader_object" }
            else
                &.{"VK_LAYER_KHRONOS_shader_object"},
        },
        .device = .{
            .extensions = &.{
                Vulkan.c.VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
                Vulkan.c.VK_EXT_EXTENDED_DYNAMIC_STATE_EXTENSION_NAME,
                Vulkan.c.VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME,
                Vulkan.c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                Vulkan.c.VK_EXT_SHADER_OBJECT_EXTENSION_NAME,
            },
        },
        .swapchain = .{
            .width = window.size.width,
            .heigth = window.size.height,
        },
    });
    return .{ .inner = vulkan_renderer };
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

fn surfaceProc(comptime CreateInfo: type, instance: Vulkan.c.VkInstance, name: [*:0]const u8) !*const fn (Vulkan.c.VkInstance, *const CreateInfo, ?*const anyopaque, *Vulkan.c.VkSurfaceKHR) callconv(.c) Vulkan.c.VkResult {
    return @ptrCast(Vulkan.c.vkGetInstanceProcAddr(instance, name) orelse return error.SurfaceProcMissing);
}

fn createVulkanSurface(instance: Vulkan.c.VkInstance, data: *anyopaque) anyerror!Vulkan.c.VkSurfaceKHR {
    const window: *Window = @ptrCast(@alignCast(data));
    var surface: Vulkan.c.VkSurfaceKHR = undefined;
    const result = switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd => switch (window.inner) {
            .wayland => |wayland| blk: {
                const create = try surfaceProc(VkWaylandSurfaceCreateInfoKHR, instance, "vkCreateWaylandSurfaceKHR");
                var create_info: VkWaylandSurfaceCreateInfoKHR = .{ .sType = 1000006000, .pNext = null, .flags = 0, .display = wayland.display, .surface = wayland.surface };
                break :blk create(instance, &create_info, null, &surface);
            },
            .x11 => |x11| blk: {
                const create = try surfaceProc(VkXlibSurfaceCreateInfoKHR, instance, "vkCreateXlibSurfaceKHR");
                var create_info: VkXlibSurfaceCreateInfoKHR = .{ .sType = 1000004000, .pNext = null, .flags = 0, .dpy = x11.display, .window = x11.window.id };
                break :blk create(instance, &create_info, null, &surface);
            },
        },
        .windows => blk: {
            const create = try surfaceProc(VkWin32SurfaceCreateInfoKHR, instance, "vkCreateWin32SurfaceKHR");
            var create_info: VkWin32SurfaceCreateInfoKHR = .{ .sType = 1000009000, .pNext = null, .flags = 0, .hinstance = window.inner.hinstance, .hwnd = window.inner.hwnd };
            break :blk create(instance, &create_info, null, &surface);
        },
        else => return error.UnsupportedPlatform,
    };
    if (result != Vulkan.c.VK_SUCCESS) return error.CreateSurface;
    return surface;
}
