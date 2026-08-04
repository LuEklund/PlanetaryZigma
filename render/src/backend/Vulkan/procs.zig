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

pub const device = struct {
    pub const ProcTable = struct {
        pub var vkCreateShadersEXT: *const fn (c.VkDevice, u32, *const c.VkShaderCreateInfoEXT, ?*const anyopaque, *c.VkShaderEXT) callconv(.c) c.VkResult = undefined;
        pub var vkDestroyShaderEXT: *const fn (c.VkDevice, c.VkShaderEXT, ?*const anyopaque) callconv(.c) void = undefined;
        pub var vkCmdBindShadersEXT: *const fn (c.VkCommandBuffer, u32, [*c]const c.VkShaderStageFlagBits, [*c]const c.VkShaderEXT) callconv(.c) void = undefined;
        pub var vkCmdSetViewportWithCountEXT: *const fn (c.VkCommandBuffer, u32, [*c]const c.VkViewport) callconv(.c) void = undefined;
        pub var vkCmdSetScissorWithCountEXT: *const fn (c.VkCommandBuffer, u32, [*c]const c.VkRect2D) callconv(.c) void = undefined;
        pub var vkCmdSetCullModeEXT: *const fn (c.VkCommandBuffer, c.VkCullModeFlags) callconv(.c) void = undefined;
        pub var vkCmdSetFrontFaceEXT: *const fn (c.VkCommandBuffer, c.VkFrontFace) callconv(.c) void = undefined;
        pub var vkCmdSetDepthTestEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetDepthWriteEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetDepthCompareOpEXT: *const fn (c.VkCommandBuffer, c.VkCompareOp) callconv(.c) void = undefined;
        pub var vkCmdSetPrimitiveTopologyEXT: *const fn (c.VkCommandBuffer, c.VkPrimitiveTopology) callconv(.c) void = undefined;
        pub var vkCmdSetRasterizerDiscardEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetPolygonModeEXT: *const fn (c.VkCommandBuffer, c.VkPolygonMode) callconv(.c) void = undefined;
        pub var vkCmdSetRasterizationSamplesEXT: *const fn (c.VkCommandBuffer, c.VkSampleCountFlagBits) callconv(.c) void = undefined;
        pub var vkCmdSetAlphaToCoverageEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetDepthBiasEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetStencilTestEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetPrimitiveRestartEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetSampleMaskEXT: *const fn (c.VkCommandBuffer, c.VkSampleCountFlagBits, [*c]const u32) callconv(.c) void = undefined;
        pub var vkCmdSetColorBlendEnableEXT: *const fn (c.VkCommandBuffer, u32, u32, [*c]const c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetColorBlendEquationEXT: *const fn (c.VkCommandBuffer, u32, u32, [*c]const c.VkColorBlendEquationEXT) callconv(.c) void = undefined;
        pub var vkCmdSetColorWriteMaskEXT: *const fn (c.VkCommandBuffer, u32, u32, [*c]const c.VkColorComponentFlags) callconv(.c) void = undefined;
        pub var vkCmdSetDepthBoundsTestEnable: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetDepthClampEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetAlphaToOneEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetLogicOpEnableEXT: *const fn (c.VkCommandBuffer, c.VkBool32) callconv(.c) void = undefined;
        pub var vkCmdSetVertexInputEXT: *const fn (c.VkCommandBuffer, u32, [*c]const c.VkVertexInputBindingDescription2EXT, u32, [*c]const c.VkVertexInputAttributeDescription2EXT) callconv(.c) void = undefined;
        pub var vkCmdBeginRendering: *const fn (c.VkCommandBuffer, [*c]const c.VkRenderingInfo) callconv(.c) void = undefined;
        pub var vkCmdEndRendering: *const fn (c.VkCommandBuffer) callconv(.c) void = undefined;
        pub var vkGetBufferDeviceAddress: *const fn (c.VkDevice, [*c]const c.VkBufferDeviceAddressInfo) callconv(.c) c.VkDeviceAddress = undefined;
        pub var vkGetDescriptorEXT: *const fn (c.VkDevice, [*c]const c.VkDescriptorGetInfoEXT, c.VkDeviceSize, ?*anyopaque) callconv(.c) void = undefined;
        pub var vkCmdBindDescriptorBuffersEXT: *const fn (c.VkCommandBuffer, u32, [*c]const c.VkDescriptorBufferBindingInfoEXT) callconv(.c) void = undefined;
        pub var vkCmdSetDescriptorBufferOffsetsEXT: *const fn (c.VkCommandBuffer, c.VkPipelineBindPoint, c.VkPipelineLayout, u32, u32, [*c]const u32, [*c]const c.VkDeviceSize) callconv(.c) void = undefined;
        pub var vkGetDescriptorSetLayoutSizeEXT: *const fn (c.VkDevice, c.VkDescriptorSetLayout, *c.VkDeviceSize) callconv(.c) void = undefined;
        pub var vkGetDescriptorSetLayoutBindingOffsetEXT: *const fn (c.VkDevice, c.VkDescriptorSetLayout, u32, *c.VkDeviceSize) callconv(.c) void = undefined;
    };
    pub fn load(vk_device: c.VkDevice, log: ?bool) void {
        const decls = @typeInfo(ProcTable).@"struct".decls;
        @setEvalBranchQuota(decls.len);
        inline for (decls) |decl| {
            const proc_addr = c.vkGetDeviceProcAddr(vk_device, decl.name);
            if (proc_addr) |addr| {
                @field(ProcTable, decl.name) = @as(@TypeOf(@field(ProcTable, decl.name)), @ptrCast(addr));
            } else {
                if (log orelse (builtin.mode == .Debug)) std.log.err("Proc '{s}' not found", .{decl.name});
            }
        }
    }
};
