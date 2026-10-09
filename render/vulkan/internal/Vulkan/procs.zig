const std = @import("std");
const builtin = @import("builtin");
const c = @import("vulkan");

pub const instance = struct {
    pub const ProcTable = struct {
        pub var vkCreateDebugUtilsMessengerEXT: *const fn (c.VkInstance, *const c.VkDebugUtilsMessengerCreateInfoEXT, ?*const anyopaque, *c.VkDebugUtilsMessengerEXT) callconv(.c) c.VkResult = undefined;
        pub var vkDestroyDebugUtilsMessengerEXT: *const fn (c.VkInstance, c.VkDebugUtilsMessengerEXT, ?*const anyopaque) callconv(.c) void = undefined;
    };

    pub fn load(vk_instance: c.VkInstance, log: ?bool) void {
        const decls = @typeInfo(ProcTable).@"struct".decls;
        @setEvalBranchQuota(decls.len);
        inline for (decls) |decl| {
            const proc_addr = c.vkGetInstanceProcAddr(vk_instance, decl.name);
            if (proc_addr) |addr| {
                @field(ProcTable, decl.name) = @as(@TypeOf(@field(ProcTable, decl.name)), @ptrCast(addr));
            } else {
                if (log orelse (builtin.mode == .Debug)) std.log.err("Proc '{s}' not found", .{decl.name});
            }
        }
    }
};
