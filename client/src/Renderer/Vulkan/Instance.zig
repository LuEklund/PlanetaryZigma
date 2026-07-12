const std = @import("std");
const c = @import("vulkan");
const check = @import("utils.zig").check;

handle: c.VkInstance,

pub fn init(gpa: std.mem.Allocator, required_extensions: []const [*:0]const u8, layers: []const [*:0]const u8) !@This() {
    var version: u32 = undefined;
    try check(c.vkEnumerateInstanceVersion(&version));
    if (c.VK_API_VERSION_MAJOR(version) < 1 or c.VK_API_VERSION_MINOR(version) < 3) return error.DynamicRenderingUnsupported;

    var count: u32 = undefined;
    try check(c.vkEnumerateInstanceExtensionProperties(null, &count, null));

    const enum_extensions: []c.VkExtensionProperties = try gpa.alloc(c.VkExtensionProperties, count);
    defer gpa.free(enum_extensions);

    try check(c.vkEnumerateInstanceExtensionProperties(null, &count, enum_extensions.ptr));

    var found: usize = 0;

    std.debug.print("amount: {d}\n", .{count});

    for (enum_extensions) |enum_extension| {
        const extension_name_len = std.mem.findScalar(u8, enum_extension.extensionName[0..], 0).?;
        for (required_extensions) |required_extension| {
            if (!std.mem.eql(u8, std.mem.span(required_extension), (enum_extension.extensionName[0..extension_name_len]))) continue;
            std.log.info("found ext: [{d}/{d}] {s}", .{ found + 1, required_extensions.len, required_extension });
            found += 1;
        }
    }
    if (found < required_extensions.len) return error.ExtensionsNotFound;

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
        .enabledLayerCount = @intCast(layers.len),
        .ppEnabledLayerNames = layers.ptr,
    };

    var instance: c.VkInstance = undefined;
    try check(c.vkCreateInstance(instane_create_info, null, @ptrCast(&instance)));
    return .{ .handle = instance };
}

pub fn deinit(self: @This()) void {
    c.vkDestroyInstance(self.handle, null);
}
