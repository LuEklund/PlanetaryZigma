const DebugMessenger = @This();

const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");

handle: vk.DebugUtilsMessengerEXT,

pub const Config = struct {
    severities: vk.DebugUtilsMessageSeverityFlagsEXT,
};

pub fn init(instance: Instance, config: Config) !DebugMessenger {
    const handle = try instance.proxy.createDebugUtilsMessengerEXT(&.{
        .message_severity = config.severities,
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .pfn_user_callback = callback,
    }, null);
    return .{ .handle = handle };
}

pub fn deinit(self: DebugMessenger, instance: Instance) void {
    instance.proxy.destroyDebugUtilsMessengerEXT(self.handle, null);
}

fn callback(
    _: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (callback_data) |data| if (data.p_message) |message| {
        _ = std.c.printf("VK:  %s\n", message);
    };
    return .false;
}
