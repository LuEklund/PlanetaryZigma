const FrameData = @This();

const vk = @import("vulkan");
const GpuMemory = @import("GpuMemory.zig");
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const DrawList = @import("renderer_contract").DrawList;

swapchain_semaphore: vk.Semaphore,
render_fence: vk.Fence,
command_buffer: vk.CommandBuffer,
gpu_scene: Buffer,
debug_vertex_buffer: Buffer,
emitter_buffer: Buffer,
joint_buffer: Buffer,
dvui_vertex_buffer: Buffer,
dvui_index_buffer: Buffer,

pub const max_frames_inflight: usize = 3;

pub const GPUEmitter = extern struct {
    origin: [3]f32,
    spawn_time: f32,
    target: [3]f32,
};

pub const DebugVertex = extern struct {
    position: [4]f32,
    color: [4]f32,
};

pub const GPUScene = extern struct {
    view_proj: [16]f32,
    inverse_proj_rotation: [16]f32,
    to_sun: [3]f32,
    time: f32,
    camera_position: [3]f32,
    planet_radius: f32 = 0,
    light_color: [4]f32,
    camera_up: [4]f32,
    sky_zenith: [4]f32,
    sky_horizon: [4]f32,
};

pub fn init(heap: *GpuMemory, device: Device) !FrameData {
    var command_buffer: vk.CommandBuffer = undefined;
    try device.proxy.allocateCommandBuffers(&.{
        .command_pool = device.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));
    const storage: vk.BufferUsageFlags = .{ .storage_buffer_bit = true, .shader_device_address_bit = true };
    const uniform: vk.BufferUsageFlags = .{ .uniform_buffer_bit = true, .storage_buffer_bit = true, .shader_device_address_bit = true };
    return .{
        .command_buffer = command_buffer,
        .swapchain_semaphore = try device.proxy.createSemaphore(&.{}, null),
        .render_fence = try device.proxy.createFence(&.{ .flags = .{ .signaled_bit = true } }, null),
        .gpu_scene = try .init(device, heap, GPUScene, 1, uniform),
        .debug_vertex_buffer = try .init(device, heap, DebugVertex, DrawList.max_lines * 2, storage),
        .emitter_buffer = try .init(device, heap, GPUEmitter, DrawList.max_emitters, storage),
        .joint_buffer = try .init(device, heap, [16]f32, DrawList.max_joint_matrices, uniform),
        .dvui_vertex_buffer = try .init(device, heap, DrawList.DvuiVertex, DrawList.max_dvui_vertices, storage),
        .dvui_index_buffer = try .init(device, heap, u32, DrawList.max_dvui_indices, .{ .index_buffer_bit = true }),
    };
}

pub fn deinit(self: *FrameData, heap: *GpuMemory, device: Device) void {
    device.proxy.destroySemaphore(self.swapchain_semaphore, null);
    device.proxy.destroyFence(self.render_fence, null);
    device.proxy.freeCommandBuffers(device.command_pool, &.{self.command_buffer});
    self.gpu_scene.deinit(heap);
    self.debug_vertex_buffer.deinit(heap);
    self.emitter_buffer.deinit(heap);
    self.joint_buffer.deinit(heap);
    self.dvui_vertex_buffer.deinit(heap);
    self.dvui_index_buffer.deinit(heap);
}
