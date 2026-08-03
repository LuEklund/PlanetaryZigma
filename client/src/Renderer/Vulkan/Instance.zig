const Instance = @This();

const std = @import("std");
const c = @import("vulkan");
const check = @import("utils.zig").check;

handle: c.VkInstance,

pub fn init(gpa: std.mem.Allocator, required_extensions: []const [*:0]const u8, layers: []const [*:0]const u8) !Instance {
    var version: u32 = undefined;
    try check(c.vkEnumerateInstanceVersion(&version));
    if (c.VK_API_VERSION_MAJOR(version) < 1 or c.VK_API_VERSION_MINOR(version) < 3) {
        std.log.err("this game needs Vulkan 1.3+, your driver reports {d}.{d} — please update your graphics drivers", .{ c.VK_API_VERSION_MAJOR(version), c.VK_API_VERSION_MINOR(version) });
        return error.DynamicRenderingUnsupported;
    }

    var count: u32 = undefined;
    try check(c.vkEnumerateInstanceExtensionProperties(null, &count, null));

    const enum_extensions: []c.VkExtensionProperties = try gpa.alloc(c.VkExtensionProperties, count);
    defer gpa.free(enum_extensions);

    try check(c.vkEnumerateInstanceExtensionProperties(null, &count, enum_extensions.ptr));

    var found: usize = 0;

    for (enum_extensions) |enum_extension| {
        const extension_name_len = std.mem.findScalar(u8, enum_extension.extensionName[0..], 0).?;
        for (required_extensions) |required_extension| {
            if (!std.mem.eql(u8, std.mem.span(required_extension), (enum_extension.extensionName[0..extension_name_len]))) continue;
            std.log.info("found ext: [{d}/{d}] {s}", .{ found + 1, required_extensions.len, required_extension });
            found += 1;
        }
    }
    if (found < required_extensions.len) {
        std.log.err("your Vulkan driver is missing required instance extensions — please update your graphics drivers", .{});
        return error.ExtensionsNotFound;
    }

    var layer_count: u32 = undefined;
    try check(c.vkEnumerateInstanceLayerProperties(&layer_count, null));
    const available_layers: []c.VkLayerProperties = try gpa.alloc(c.VkLayerProperties, layer_count);
    defer gpa.free(available_layers);
    try check(c.vkEnumerateInstanceLayerProperties(&layer_count, available_layers.ptr));

    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_layers.deinit(gpa);
    for (layers) |requested_layer| {
        const requested_name = std.mem.span(requested_layer);
        for (available_layers) |available_layer| {
            const available_name_len = std.mem.findScalar(u8, available_layer.layerName[0..], 0).?;
            if (std.mem.eql(u8, requested_name, available_layer.layerName[0..available_name_len])) {
                try enabled_layers.append(gpa, requested_layer);
                break;
            }
        } else std.log.warn("vulkan layer not installed, skipping: {s}", .{requested_layer});
    }

    const instane_create_info: *const c.VkInstanceCreateInfo = &.{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &.{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "PlanetaryZigma",
            .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "Zigma",
            .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_4,
        },
        .enabledExtensionCount = @intCast(required_extensions.len),
        .ppEnabledExtensionNames = required_extensions.ptr,
        .enabledLayerCount = @intCast(enabled_layers.items.len),
        .ppEnabledLayerNames = enabled_layers.items.ptr,
    };

    var instance: c.VkInstance = undefined;
    try check(c.vkCreateInstance(instane_create_info, null, @ptrCast(&instance)));
    return .{ .handle = instance };
}

pub fn deinit(self: Instance) void {
    c.vkDestroyInstance(self.handle, null);
}
