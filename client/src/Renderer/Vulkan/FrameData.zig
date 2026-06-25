const std = @import("std");
const c = @import("vulkan");
const Vma = @import("Vma.zig");
const Func = @import("utils.zig").Func;
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const Ui = @import("Ui.zig");
const check = @import("utils.zig").check;

swapchain_semaphore: c.VkSemaphore,
render_fence: c.VkFence,
command_buffer: c.VkCommandBuffer,
gpu_scene: Buffer,
ui_vertex_buffer: Buffer,

pub const GPUScene = extern struct {
    view_proj: [16]f32,
    inverse_view_proj: [16]f32,
    global_light_direction: [3]f32,
    time: f32,
    camera_position: [3]f32,
};

pub fn init(vma: Vma, device: Device) !@This() {
    var alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = device.command_pool.handle,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var command_buffer: c.VkCommandBuffer = undefined;
    try check(c.vkAllocateCommandBuffers(device.handle, &alloc_info, &command_buffer));

    var semaphoreCreateInfo: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };
    var swapchain_semaphore: c.VkSemaphore = undefined;
    try check(c.vkCreateSemaphore(device.handle, &semaphoreCreateInfo, null, &swapchain_semaphore));

    var fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    var render_fence: c.VkFence = undefined;
    try check(c.vkCreateFence(device.handle, &fence_info, null, &render_fence));

    return .{
        .command_buffer = command_buffer,
        .swapchain_semaphore = swapchain_semaphore,
        .render_fence = render_fence,
        .gpu_scene = try .init(
            device,
            vma,
            GPUScene,
            1,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        ),
        .ui_vertex_buffer = try .init(
            device,
            vma,
            Ui.Vertex,
            Ui.max_ui_quads * 4,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        ),
    };
}

pub fn deinit(self: *@This(), vma: Vma, device: Device) void {
    c.vkDestroySemaphore(device.handle, self.swapchain_semaphore, null);
    c.vkDestroyFence(device.handle, self.render_fence, null);
    c.vkFreeCommandBuffers(device.handle, device.command_pool.handle, 1, &self.command_buffer);
    self.gpu_scene.deinit(vma);
    self.ui_vertex_buffer.deinit(vma);
}
