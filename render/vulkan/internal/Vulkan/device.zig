const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");

pub const Physical = struct {
    handle: vk.PhysicalDevice,
    max_anisotropy: f32,
    graphics_queue_family_index: u32,
    memory_properties: vk.PhysicalDeviceMemoryProperties,

    pub fn pick(gpa: std.mem.Allocator, instance: Instance, surface: vk.SurfaceKHR) !Physical {
        const devices = try instance.proxy.enumeratePhysicalDevicesAlloc(gpa);
        defer gpa.free(devices);
        if (devices.len == 0) return error.NoPhysicalDevices;

        for (devices) |device| {
            const properties = instance.proxy.getPhysicalDeviceProperties(device);
            const device_name = std.mem.sliceTo(&properties.device_name, 0);
            const version: vk.Version = @bitCast(properties.api_version);
            if (version.major == 1 and version.minor < 3) {
                std.log.info("skipping {s}: Vulkan {d}.{d} < 1.3", .{ device_name, version.major, version.minor });
                continue;
            }

            const families = try instance.proxy.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, gpa);
            defer gpa.free(families);
            for (families, 0..) |family, family_index| {
                const present_supported = try instance.proxy.getPhysicalDeviceSurfaceSupportKHR(device, @intCast(family_index), surface);
                if (!family.queue_flags.graphics_bit or present_supported != .true) continue;
                std.log.info("found physical device: {s}, queue family: {d}", .{ device_name, family_index });
                return .{
                    .handle = device,
                    .max_anisotropy = properties.limits.max_sampler_anisotropy,
                    .graphics_queue_family_index = @intCast(family_index),
                    .memory_properties = instance.proxy.getPhysicalDeviceMemoryProperties(device),
                };
            }
        }
        return error.NoSuitablePhysicalDevice;
    }
};

pub const Logical = struct {
    handle: vk.Device,
    proxy: vk.DeviceProxy,
    immediate_fence: vk.Fence,
    graphics_queue: vk.Queue,
    command_pool: vk.CommandPool,

    pub fn init(gpa: std.mem.Allocator, instance: Instance, physical_device: Physical) !Logical {
        const extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
        const available = try instance.proxy.enumerateDeviceExtensionPropertiesAlloc(physical_device.handle, null, gpa);
        defer gpa.free(available);
        check_ext: for (extensions) |extension| {
            for (available) |candidate|
                if (std.mem.eql(u8, std.mem.span(extension), std.mem.sliceTo(&candidate.extension_name, 0))) continue :check_ext;
            std.log.err("your GPU/driver does not support the required Vulkan feature {s} — please update your graphics drivers; if that does not help, your GPU may be too old for this game", .{extension});
            return error.MissingDeviceExtension;
        }

        const queue_priority = [_]f32{1.0};
        const queue_info = [_]vk.DeviceQueueCreateInfo{.{
            .queue_family_index = physical_device.graphics_queue_family_index,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        }};

        const features = instance.proxy.getPhysicalDeviceFeatures(physical_device.handle);
        var vulkan13_features: vk.PhysicalDeviceVulkan13Features = .{
            .dynamic_rendering = .true,
            .synchronization_2 = .true,
        };
        var vulkan12_features: vk.PhysicalDeviceVulkan12Features = .{
            .p_next = &vulkan13_features,
            .buffer_device_address = .true,
            .descriptor_indexing = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_update_unused_while_pending = .true,
            .descriptor_binding_partially_bound = .true,
        };
        var vulkan11_features: vk.PhysicalDeviceVulkan11Features = .{
            .p_next = &vulkan12_features,
            .shader_draw_parameters = .true,
        };

        const handle = try instance.proxy.createDevice(physical_device.handle, &.{
            .p_next = &vulkan11_features,
            .queue_create_info_count = queue_info.len,
            .p_queue_create_infos = &queue_info,
            .p_enabled_features = &features,
            .enabled_extension_count = extensions.len,
            .pp_enabled_extension_names = &extensions,
        }, null);

        const api = try gpa.create(vk.DeviceWrapper);
        errdefer gpa.destroy(api);
        api.* = .load(handle, instance.api.dispatch.vkGetDeviceProcAddr.?);
        const proxy: vk.DeviceProxy = .init(handle, api);
        errdefer proxy.destroyDevice(null);

        const command_pool = try proxy.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = physical_device.graphics_queue_family_index,
        }, null);
        const immediate_fence = try proxy.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        return .{
            .handle = handle,
            .proxy = proxy,
            .graphics_queue = proxy.getDeviceQueue(physical_device.graphics_queue_family_index, 0),
            .command_pool = command_pool,
            .immediate_fence = immediate_fence,
        };
    }

    pub fn deinit(self: Logical, gpa: std.mem.Allocator) void {
        self.proxy.destroyCommandPool(self.command_pool, null);
        self.proxy.destroyFence(self.immediate_fence, null);
        self.proxy.destroyDevice(null);
        gpa.destroy(@constCast(self.proxy.wrapper));
    }

    pub fn beginImmediateCommand(self: Logical) !vk.CommandBuffer {
        var command_buffer: vk.CommandBuffer = undefined;
        try self.proxy.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));
        try self.proxy.resetFences(&.{self.immediate_fence});
        try self.proxy.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        return command_buffer;
    }

    pub fn endImmediateCommand(self: Logical, command_buffer: vk.CommandBuffer) !void {
        try self.proxy.endCommandBuffer(command_buffer);
        const submit = [_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        }};
        try self.proxy.queueSubmit(self.graphics_queue, &submit, self.immediate_fence);
        _ = try self.proxy.waitForFences(&.{self.immediate_fence}, .true, std.math.maxInt(u64));
        self.proxy.freeCommandBuffers(self.command_pool, &.{command_buffer});
    }
};
