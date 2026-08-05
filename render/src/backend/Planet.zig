const Planet = @This();

const std = @import("std");
const shared = @import("shared");
const Mesh = @import("Vulkan/Mesh.zig");
const Vma = @import("Vulkan/Vma.zig");
const Device = @import("Vulkan/device.zig").Logical;
const FrameData = @import("Vulkan/FrameData.zig");

meshes: std.AutoArrayHashMapUnmanaged(shared.Planet.Chunk.Coord, Mesh),
retired: std.ArrayList(RetiredChunk),

const RetiredChunk = struct {
    mesh: Mesh,
    frame: u32,
};

pub fn init() Planet {
    return .{
        .meshes = .empty,
        .retired = .empty,
    };
}

pub fn deinit(self: *Planet, gpa: std.mem.Allocator, vma: Vma) void {
    for (self.meshes.values()) |*mesh| mesh.deinit(gpa, vma);
    self.meshes.deinit(gpa);
    for (self.retired.items) |*retired_chunk| retired_chunk.mesh.deinit(gpa, vma);
    self.retired.deinit(gpa);
}

pub fn upload(self: *Planet, gpa: std.mem.Allocator, vma: Vma, device: Device, command: shared.Planet.Upload, frame: u32) !void {
    try self.remove(gpa, command.coord, frame);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}", .{ command.coord.position[0], command.coord.position[1], command.coord.position[2] });
    const mesh = try Mesh.init(gpa, vma, name, device, Mesh.StaticVertex, command.vertices, command.indices, &.{.{ .index_start = 0, .index_count = @intCast(command.indices.len), .texture = .blank }});
    try self.meshes.put(gpa, command.coord, mesh);
}

pub fn remove(self: *Planet, gpa: std.mem.Allocator, coord: shared.Planet.Chunk.Coord, frame: u32) !void {
    const old = self.meshes.fetchSwapRemove(coord) orelse return;
    try self.retired.append(gpa, .{ .mesh = old.value, .frame = frame });
}

pub fn drainRetired(self: *Planet, gpa: std.mem.Allocator, vma: Vma, frame: u32) void {
    var retired_index: usize = self.retired.items.len;
    while (retired_index > 0) {
        retired_index -= 1;
        const retired_chunk = &self.retired.items[retired_index];
        if (frame >= retired_chunk.frame + FrameData.max_frames_inflight) {
            retired_chunk.mesh.deinit(gpa, vma);
            _ = self.retired.swapRemove(retired_index);
        }
    }
}
