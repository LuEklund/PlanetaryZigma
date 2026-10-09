const Instance = @This();

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

handle: vk.Instance,
base: *vk.BaseWrapper,
api: *vk.InstanceWrapper,
proxy: vk.InstanceProxy,

extern fn vkGetInstanceProcAddr(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

const layers: []const [*:0]const u8 = if (builtin.mode == .Debug)
    &.{"VK_LAYER_KHRONOS_validation"}
else
    &.{};

pub fn init(gpa: std.mem.Allocator, required_extensions: []const [*:0]const u8) !Instance {
    const base = try gpa.create(vk.BaseWrapper);
    errdefer gpa.destroy(base);
    base.* = .load(vkGetInstanceProcAddr);

    const version: vk.Version = @bitCast(try base.enumerateInstanceVersion());
    if (version.major < 1 or (version.major == 1 and version.minor < 3)) {
        std.log.err("this game needs Vulkan 1.3+, your driver reports {d}.{d} — please update your graphics drivers", .{ version.major, version.minor });
        return error.VulkanVersionUnsupported;
    }

    const available_extensions = try base.enumerateInstanceExtensionPropertiesAlloc(null, gpa);
    defer gpa.free(available_extensions);
    var found: usize = 0;
    for (available_extensions) |available_extension| {
        const available_name = std.mem.sliceTo(&available_extension.extension_name, 0);
        for (required_extensions) |required_extension| {
            if (!std.mem.eql(u8, std.mem.span(required_extension), available_name)) continue;
            std.log.info("found ext: [{d}/{d}] {s}", .{ found + 1, required_extensions.len, required_extension });
            found += 1;
        }
    }
    if (found < required_extensions.len) {
        std.log.err("your Vulkan driver is missing required instance extensions — please update your graphics drivers", .{});
        return error.ExtensionsNotFound;
    }

    const available_layers = try base.enumerateInstanceLayerPropertiesAlloc(gpa);
    defer gpa.free(available_layers);
    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_layers.deinit(gpa);
    for (layers) |requested_layer| {
        for (available_layers) |available_layer| {
            if (std.mem.eql(u8, std.mem.span(requested_layer), std.mem.sliceTo(&available_layer.layer_name, 0))) {
                try enabled_layers.append(gpa, requested_layer);
                break;
            }
        } else std.log.warn("vulkan layer not installed, skipping: {s}", .{requested_layer});
    }

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "PlanetaryZigma",
        .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .p_engine_name = "Zigma",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .api_version = vk.API_VERSION_1_3.toU32(),
    };
    const handle = try base.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(required_extensions.len),
        .pp_enabled_extension_names = required_extensions.ptr,
        .enabled_layer_count = @intCast(enabled_layers.items.len),
        .pp_enabled_layer_names = enabled_layers.items.ptr,
    }, null);

    const api = try gpa.create(vk.InstanceWrapper);
    errdefer gpa.destroy(api);
    api.* = .load(handle, base.dispatch.vkGetInstanceProcAddr.?);
    return .{ .handle = handle, .base = base, .api = api, .proxy = .init(handle, api) };
}

pub fn deinit(self: Instance, gpa: std.mem.Allocator) void {
    self.proxy.destroyInstance(null);
    gpa.destroy(self.api);
    gpa.destroy(self.base);
}
