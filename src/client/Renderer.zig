const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");

instance: vulkan.Instance,

pub const Vertex = extern struct {
    position: [3]f32,
    color: [4]f32,
    // TODO(etakarinaee): uv
};

pub const Texture = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,
};

pub fn init() vulkan.Error!Renderer {
    var instance: vulkan.Instance = try .init(&.{}, &.{});
    errdefer instance.deinit();

    return .{ .instance = instance };
}

pub fn deinit(renderer: *Renderer) void {
    renderer.instance.deinit();

    renderer.* = undefined;
}

pub fn draw(renderer: *Renderer) void {
    _ = .{renderer};
    std.debug.panic("TODO: draw", .{});
}

pub const vulkan = struct {
    const log = std.log.scoped(.vulkan);
    /// validation layers tank performance a lot, therefore they are enabled in Debug and ONLY in Debug
    ///
    /// zig std has the pattern of enabling debug things in ReleaseSafe, but validation layers do not really provide any 'safety' features and are only needed
    /// during development process
    pub const enable_validation = switch (builtin.mode) {
        .Debug => true,
        else => false,
    };

    pub const Instance = struct {
        handle: vk.VkInstance,

        pub fn init(extensions: []const [*:0]const u8, layers: []const [*:0]const u8) Error!Instance {
            var version: u32 = undefined;
            try check(vk.vkEnumerateInstanceVersion(&version));

            const major = vk.VK_API_VERSION_MAJOR(version);
            const minor = vk.VK_API_VERSION_MINOR(version);

            if (major < 1 or minor < 4) {
                log.err("unsupported vulkan version: {d}.{d}", .{ major, minor });
                return error.InitializationFailed;
            }

            var instance: vk.VkInstance = undefined;
            const instance_create_info: *const vk.VkInstanceCreateInfo = &.{
                .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                .pApplicationInfo = &.{
                    .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
                    .pApplicationName = "PlanetaryZigma",
                    .applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0),
                    .pEngineName = "etakarinaee",
                    .engineVersion = vk.VK_MAKE_VERSION(1, 0, 0),
                    .apiVersion = vk.VK_API_VERSION_1_4,
                },
                .enabledExtensionCount = @intCast(extensions.len),
                .ppEnabledExtensionNames = extensions.ptr,
                .enabledLayerCount = @intCast(layers.len),
                .ppEnabledLayerNames = layers.ptr,
            };
            try check(vk.vkCreateInstance(instance_create_info, null, @ptrCast(&instance)));

            return .{
                .handle = instance,
            };
        }

        fn initDebugMessenger(instance: Instance) Error!vk.VkDebugUtilsMessengerEXT {
            if (!enable_validation) {
                return;
            }

            const debug_messenger_create_info = initDebugMessengerCreateInfo();
            const PFN_vkCreateDebugUtilsMessengerEXT: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(
                vk.vkGetInstancProcAddr(instance.handle, "vkCreateDebugUtilsMessengerEXT"),
            );

            var debug_messenger: vk.VkDebugUtilsMessengerEXT = undefined;

            if (PFN_vkCreateDebugUtilsMessengerEXT) |vkCreateDebugUtilsMessengerEXT| {
                check(vkCreateDebugUtilsMessengerEXT(instance.handle, &debug_messenger_create_info, null, &debug_messenger));
            } else {
                std.log.err("note: validation layers were enabled, but vkCreateDebugUtilsMessengerEXT proc is not available", .{});
                return error.InitializationFailed;
            }
        }

        pub fn deinit(instance: *Instance) void {
            vk.vkDestroyInstance(instance.handle, null);

            instance.* = undefined;
        }
    };

    fn initDebugMessengerCreateInfo() vk.VkDebugUtilsMessengerCreateInfoEXT {
        return .{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = userCallback,
            .pUserData = null,
        };
    }

    // debug callback
    fn userCallback(
        severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
        message_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
        callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
        user_data: ?*anyopaque,
    ) callconv(.c) vk.VkBool32 {
        _ = .{ severity, message_type, user_data };

        if (callback_data) |data| if (data.pMessage) |message| {
            const logFn = switch (severity) {
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => {},
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => std.log.info,
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => std.log.warn,
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => std.log.err,
                else => unreachable,
            };
            logFn(message, .{});
        };

        return vk.VK_FALSE;
    }

    pub const Error = error{
        NotReady,
        Timeout,
        EventSet,
        EventReset,
        Incomplete,
        OutOfHostMemory,
        OutOfDeviceMemory,
        InitializationFailed,
        DeviceLost,
        MemoryMapFailed,
        LayerNotPresent,
        ExtensionNotPresent,
        FeatureNotPresent,
        IncompatibleDriver,
        TooManyObjects,
        FormatNotSupported,
        FragmentedPool,
        ValidationFailed,
        OutOfPoolMemory,
        InvalidExternalHandle,
        InvalidOpaqueCaptureAddress,
        Fragmentation,
        PipelineCompileRequired,
        NotPermitted,
        SurfaceLostKhr,
        NativeWindowInUseKhr,
        SuboptimalKhr,
        OutOfDateKhr,
        IncompatibleDisplayKhr,
        InvalidShaderNv,
        ImageUsageNotSupportedKhr,
        VideoPictureLayoutNotSupportedKhr,
        VideoProfileOperationNotSupportedKhr,
        VideoProfileFormatNotSupportedKhr,
        VideoProfileCodecNotSupportedKhr,
        VideoStdVersionNotSupportedKhr,
        InvalidDrmFormatModifierPlaneLayoutExt,
        PresentTimingQueueFullExt,
        FullScreenExclusiveModeLostExt,
        ThreadIdleKhr,
        ThreadDoneKhr,
        OperationDeferredKhr,
        OperationNotDeferredKhr,
        InvalidVideoStdParametersKhr,
        CompressionExhaustedExt,
        IncompatibleShaderBinaryExt,
        PipelineBinaryMissingKhr,
        NotEnoughSpaceKhr,
        Unknown,
    };

    pub fn check(result: vk.VkResult) Error!void {
        return switch (result) {
            vk.VK_SUCCESS => {},
            vk.VK_NOT_READY => error.NotReady,
            vk.VK_TIMEOUT => error.Timeout,
            vk.VK_EVENT_SET => error.EventSet,
            vk.VK_EVENT_RESET => error.EventReset,
            vk.VK_INCOMPLETE => error.Incomplete,
            vk.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
            vk.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
            vk.VK_ERROR_DEVICE_LOST => error.DeviceLost,
            vk.VK_ERROR_MEMORY_MAP_FAILED => error.MemoryMapFailed,
            vk.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
            vk.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
            vk.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
            vk.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
            vk.VK_ERROR_TOO_MANY_OBJECTS => error.TooManyObjects,
            vk.VK_ERROR_FORMAT_NOT_SUPPORTED => error.FormatNotSupported,
            vk.VK_ERROR_FRAGMENTED_POOL => error.FragmentedPool,
            vk.VK_ERROR_UNKNOWN => error.Unknown,
            vk.VK_ERROR_VALIDATION_FAILED => error.ValidationFailed,
            vk.VK_ERROR_OUT_OF_POOL_MEMORY => error.OutOfPoolMemory,
            vk.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.InvalidExternalHandle,
            vk.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.InvalidOpaqueCaptureAddress,
            vk.VK_ERROR_FRAGMENTATION => error.Fragmentation,
            vk.VK_PIPELINE_COMPILE_REQUIRED => error.PipelineCompileRequired,
            vk.VK_ERROR_NOT_PERMITTED => error.NotPermitted,
            vk.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLostKhr,
            vk.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.NativeWindowInUseKhr,
            vk.VK_SUBOPTIMAL_KHR => error.SuboptimalKhr,
            vk.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDateKhr,
            vk.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.IncompatibleDisplayKhr,
            vk.VK_ERROR_INVALID_SHADER_NV => error.InvalidShaderNv,
            vk.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => error.ImageUsageNotSupportedKhr,
            vk.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => error.VideoPictureLayoutNotSupportedKhr,
            vk.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => error.VideoProfileOperationNotSupportedKhr,
            vk.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => error.VideoProfileFormatNotSupportedKhr,
            vk.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => error.VideoProfileCodecNotSupportedKhr,
            vk.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => error.VideoStdVersionNotSupportedKhr,
            vk.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.InvalidDrmFormatModifierPlaneLayoutExt,
            vk.VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT => error.PresentTimingQueueFullExt,
            vk.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.FullScreenExclusiveModeLostExt,
            vk.VK_THREAD_IDLE_KHR => error.ThreadIdleKhr,
            vk.VK_THREAD_DONE_KHR => error.ThreadDoneKhr,
            vk.VK_OPERATION_DEFERRED_KHR => error.OperationDeferredKhr,
            vk.VK_OPERATION_NOT_DEFERRED_KHR => error.OperationNotDeferredKhr,
            vk.VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR => error.InvalidVideoStdParametersKhr,
            vk.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.CompressionExhaustedExt,
            vk.VK_INCOMPATIBLE_SHADER_BINARY_EXT => error.IncompatibleShaderBinaryExt,
            vk.VK_PIPELINE_BINARY_MISSING_KHR => error.PipelineBinaryMissingKhr,
            vk.VK_ERROR_NOT_ENOUGH_SPACE_KHR => error.NotEnoughSpaceKhr,
            else => error.Unknown,
        };
    }
};

const Renderer = @This();
