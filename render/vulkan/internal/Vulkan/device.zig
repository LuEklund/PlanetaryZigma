const std = @import("std");
const c = @import("vulkan");
const Instance = @import("Instance.zig");
const check = @import("utils.zig").check;

pub const Physical = struct {
    handle: c.VkPhysicalDevice,
    max_anisotropy: f32,
    graphics_queue_family_index: u32,

    pub fn pick(instance: Instance, surface: c.VkSurfaceKHR) !Physical {
        var device_count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(instance.handle, &device_count, null));
        if (device_count == 0) return error.NoPhysicalDevices;

        var devices: [8]c.VkPhysicalDevice = undefined;
        try check(c.vkEnumeratePhysicalDevices(instance.handle, &device_count, &devices));

        for (devices[0..device_count]) |device| {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(device, &properties);

            var family_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);

            var families: [16]c.VkQueueFamilyProperties = undefined;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, &families);

            for (families[0..family_count], 0..) |family, i| {
                const supports_graphics = (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0;

                var present_supported: c.VkBool32 = undefined;
                try check(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_supported));

                if (supports_graphics and present_supported != 0) {
                    const device_name = std.mem.sliceTo(&properties.deviceName, 0);
                    std.log.info("found physical device: {s}, queue family: {d}", .{ device_name, i });

                    return .{
                        .handle = device,
                        .max_anisotropy = properties.limits.maxSamplerAnisotropy,
                        .graphics_queue_family_index = @intCast(i),
                    };
                }
            }
        }
        return error.NoSuitablePhysicalDevice;
    }
};

pub const Logical = struct {
    handle: c.VkDevice,
    immediate_fence: c.VkFence,
    graphics_queue: c.VkQueue,
    command_pool: CommandPool,

    pub const CommandPool = struct {
        handle: c.VkCommandPool,

        pub fn init(device: c.VkDevice, queue_family_index: u32) !CommandPool {
            const command_pool_info: c.VkCommandPoolCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .pNext = null,
                .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                .queueFamilyIndex = queue_family_index,
            };

            var command_pool: c.VkCommandPool = undefined;
            try check(c.vkCreateCommandPool(device, &command_pool_info, null, &command_pool));
            return .{ .handle = command_pool };
        }

        pub fn deinit(self: CommandPool, device: Logical) void {
            c.vkDestroyCommandPool(device.handle, self.handle, null);
        }
    };

    pub fn init(physical_device: Physical) !Logical {
        const extensions: []const [*:0]const u8 = &.{
            c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        };
        var extension_count: u32 = undefined;
        try check(c.vkEnumerateDeviceExtensionProperties(physical_device.handle, null, &extension_count, null));
        var extension_properties: [516]c.VkExtensionProperties = undefined;
        try check(c.vkEnumerateDeviceExtensionProperties(physical_device.handle, null, &extension_count, &extension_properties));
        check_ext: for (extensions) |extension| {
            for (extension_properties[0..extension_count]) |cmp_ext|
                if (std.mem.eql(u8, std.mem.span(extension), std.mem.sliceTo(&cmp_ext.extensionName, 0))) continue :check_ext;
            std.log.err("your GPU/driver does not support the required Vulkan feature {s} — please update your graphics drivers; if that does not help, your GPU may be too old for this game", .{extension});
            return error.MissingDeviceExtension;
        }

        var queue_priority: f32 = 1.0;
        const queue_info: c.VkDeviceQueueCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .queueFamilyIndex = physical_device.graphics_queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
            .flags = 0,
        };

        var features: c.VkPhysicalDeviceFeatures = undefined;
        c.vkGetPhysicalDeviceFeatures(physical_device.handle, &features);

        var vulkan13_features: c.VkPhysicalDeviceVulkan13Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .dynamicRendering = c.VK_TRUE,
            .synchronization2 = c.VK_TRUE,
        };
        var vulkan12_features: c.VkPhysicalDeviceVulkan12Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            .pNext = &vulkan13_features,
            .bufferDeviceAddress = c.VK_TRUE,
            .descriptorIndexing = c.VK_TRUE,
            .shaderSampledImageArrayNonUniformIndexing = c.VK_TRUE,
            .descriptorBindingSampledImageUpdateAfterBind = c.VK_TRUE,
            .descriptorBindingUpdateUnusedWhilePending = c.VK_TRUE,
            .descriptorBindingPartiallyBound = c.VK_TRUE,
        };
        var vulkan11_features: c.VkPhysicalDeviceVulkan11Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .pNext = &vulkan12_features,
            .shaderDrawParameters = c.VK_TRUE,
        };

        const device_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &vulkan11_features,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .pEnabledFeatures = &features,
            .enabledExtensionCount = @intCast(extensions.len),
            .ppEnabledExtensionNames = extensions.ptr,
        };

        var device: c.VkDevice = undefined;
        try check(c.vkCreateDevice(physical_device.handle, &device_info, null, &device));
        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, physical_device.graphics_queue_family_index, 0, &queue);

        const command_pool: CommandPool = try .init(device, physical_device.graphics_queue_family_index);
        var fence_info: c.VkFenceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        var fence: c.VkFence = undefined;
        try check(c.vkCreateFence(device, &fence_info, null, &fence));
        return .{
            .handle = device,
            .graphics_queue = queue,
            .command_pool = command_pool,
            .immediate_fence = fence,
        };
    }

    pub fn deinit(self: Logical) void {
        self.command_pool.deinit(self);
        c.vkDestroyFence(self.handle, self.immediate_fence, null);
        c.vkDestroyDevice(self.handle, null);
    }

    pub fn beginImmediateCommand(
        device: Logical,
    ) !c.VkCommandBuffer {
        var alloc_info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandPool = device.command_pool.handle,
            .commandBufferCount = 1,
        };

        var command_buffer: c.VkCommandBuffer = undefined;
        try check(c.vkAllocateCommandBuffers(device.handle, &alloc_info, &command_buffer));

        try check(c.vkResetFences(device.handle, 1, &device.immediate_fence));
        try check(c.vkResetCommandBuffer(command_buffer, 0));

        var begin_info: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };

        try check(c.vkBeginCommandBuffer(command_buffer, &begin_info));
        return command_buffer;
    }

    pub fn endImmediateCommand(
        device: Logical,
        command_buffer: c.VkCommandBuffer,
    ) !void {
        try check(c.vkEndCommandBuffer(command_buffer));

        var submit_info: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
        };

        try check(c.vkQueueSubmit(device.graphics_queue, 1, &submit_info, device.immediate_fence));

        try check(c.vkWaitForFences(device.handle, 1, &device.immediate_fence, 1, 9999999999));

        c.vkFreeCommandBuffers(device.handle, device.command_pool.handle, 1, &command_buffer);
    }
};
