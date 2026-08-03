const Navmesh = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;

const max_chunks: usize = 256;
const max_nodes_per_chunk: usize = 4096;
const delete_after_unused_seconds: f32 = 10;

pub const Chunk = struct {
    node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
    last_used_time: f32,
};

chunks: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Chunk),

pub fn init(gpa: std.mem.Allocator) !Navmesh {
    var chunks: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Chunk) = .empty;
    try chunks.ensureTotalCapacity(gpa, max_chunks);
    return .{ .chunks = chunks };
}

pub fn deinit(self: *Navmesh, gpa: std.mem.Allocator) void {
    self.clear(gpa);
    self.chunks.deinit(gpa);
}

pub fn clear(self: *Navmesh, gpa: std.mem.Allocator) void {
    for (self.chunks.values()) |*chunk| chunk.node_map.deinit(gpa);
    self.chunks.clearRetainingCapacity();
}

pub fn ensure(self: *Navmesh, gpa: std.mem.Allocator, position: nz.Vec3(f32), planet_radius: f32, time: f32) !void {
    const coord = shared.planet.Chunk.Coord.fromPosition(position);
    if (self.chunks.getPtr(coord.position)) |chunk| {
        chunk.last_used_time = time;
        return;
    }
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const cell_min = shared.planet.Chunk.min(coord);
    const cell_max = shared.planet.Chunk.max(coord);
    const density = try shared.planet.sdf.DensityGrid.initRegion(gpa, planet_radius, cell_min, cell_max);
    defer density.deinit(gpa);
    var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
    errdefer node_map.deinit(gpa);
    try node_map.ensureTotalCapacity(gpa, max_nodes_per_chunk);
    try shared.planet.sdf.surface_nodes.buildRegion(gpa, &node_map, &density, cell_min, cell_max);
    std.debug.assert(node_map.count() <= max_nodes_per_chunk);
    self.chunks.putAssumeCapacityNoClobber(coord.position, .{ .node_map = node_map, .last_used_time = time });
}

pub fn deleteUnused(self: *Navmesh, gpa: std.mem.Allocator, time: f32) void {
    var index: usize = self.chunks.count();
    while (index > 0) {
        index -= 1;
        const chunk = &self.chunks.values()[index];
        if (time - chunk.last_used_time < delete_after_unused_seconds) continue;
        chunk.node_map.deinit(gpa);
        self.chunks.swapRemoveAt(index);
    }
}
