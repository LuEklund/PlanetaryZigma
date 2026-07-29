const Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const World = @import("System.zig").World;
const AssetServer = @import("AssetServer.zig");
const AnimationInstance = @import("asset/AnimationInstance.zig");
const Ui = @import("Ui.zig");
const yes = @import("yes");
const tracy = @import("ztracy");

inner: Inner,

const Vulkan = @import("Renderer/Vulkan.zig");

pub const Inner = *Vulkan;

pub const TextureTable = @import("Renderer/loader/TextureTable.zig");

pub fn init(gpa: std.mem.Allocator, asset_server: *AssetServer, desktop: yes.Desktop, window: *yes.Window) !Renderer {
    return switch (builtin.os.tag) {
        else => initVulkan(gpa, asset_server, desktop, window),
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

pub fn update(self: *Renderer, world: *World, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance), ui: *const Ui) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try self.inner.update(world, instances, ui);
}

const debug_instance_extensions = if (builtin.mode == .Debug)
    [_][*:0]const u8{Vulkan.c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME}
else
    [_][*:0]const u8{};

pub fn resize(self: *Renderer, gpa: std.mem.Allocator, window: *yes.Window) !void {
    try self.inner.resize(gpa, window.size.width, window.size.height);
}

pub fn initVulkan(gpa: std.mem.Allocator, asset_server: *AssetServer, desktop: yes.Desktop, window: *yes.Window) !Renderer {
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
        } else switch (window.native(desktop)) {
            .wayland => &(debug_instance_extensions ++ [_][*:0]const u8{
                Vulkan.c.VK_KHR_SURFACE_EXTENSION_NAME,
                Vulkan.c.VK_KHR_DISPLAY_EXTENSION_NAME,

                "VK_KHR_surface",
                "VK_KHR_display",
                "VK_KHR_wayland_surface",
            }),
            .x => &(debug_instance_extensions ++ [_][*:0]const u8{
                Vulkan.c.VK_KHR_SURFACE_EXTENSION_NAME,
                Vulkan.c.VK_KHR_DISPLAY_EXTENSION_NAME,

                "VK_KHR_surface",
                "VK_KHR_display",
                "VK_KHR_xlib_surface",
                "VK_KHR_xcb_surface",
            }),
            else => &.{},
        },
        else => &.{},
    };

    var yes_surface_create_user_data: YesSurfaceCreateUserData = .{ .desktop = desktop, .window = window };

    const vulkan_renderer: *Vulkan = try .init(gpa, asset_server, .{
        .surface = .{
            .data = @ptrCast(@alignCast(&yes_surface_create_user_data)),
            .init = @ptrCast(&createVulkanSurface),
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

const YesSurfaceCreateUserData = struct {
    desktop: yes.Desktop,
    window: *yes.Window,
};

fn createVulkanSurface(instance: *Vulkan.c.VkInstance, user_data: *const YesSurfaceCreateUserData) !Vulkan.c.VkSurfaceKHR {
    return @ptrCast(try yes.vulkan.createSurface(user_data.desktop, user_data.window, @ptrCast(instance), null, @ptrCast(&Vulkan.c.vkGetInstanceProcAddr)));
}
