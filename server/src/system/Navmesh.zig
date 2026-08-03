const Navmesh = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;

const max_chunks: usize = 256;
const max_nodes_per_chunk: usize = 4096;
const delete_after_unused_seconds: f32 = 10;
const max_flow_nodes: usize = 32768;
pub const flow_rebuild_ticks: u32 = 6;

const neighbor_offsets: [26]nz.Vec3(i32) = offsets: {
    var result: [26]nz.Vec3(i32) = undefined;
    var index: usize = 0;
    for ([3]i32{ -1, 0, 1 }) |x| for ([3]i32{ -1, 0, 1 }) |y| for ([3]i32{ -1, 0, 1 }) |z| {
        if (x == 0 and y == 0 and z == 0) continue;
        result[index] = .{ x, y, z };
        index += 1;
    };
    break :offsets result;
};

pub const Chunk = struct {
    node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
    last_used_time: f32,
};

pub const FlowNode = struct {
    centroid: nz.Vec3(f32),
    distance: u16,
};

chunks: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Chunk),
flow: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), FlowNode),
flow_queue: std.ArrayList(nz.Vec3(i32)),

pub fn init(gpa: std.mem.Allocator) !Navmesh {
    var chunks: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Chunk) = .empty;
    try chunks.ensureTotalCapacity(gpa, max_chunks);
    var flow: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), FlowNode) = .empty;
    try flow.ensureTotalCapacity(gpa, max_flow_nodes);
    return .{
        .chunks = chunks,
        .flow = flow,
        .flow_queue = try .initCapacity(gpa, max_flow_nodes),
    };
}

pub fn deinit(self: *Navmesh, gpa: std.mem.Allocator) void {
    self.clear(gpa);
    self.chunks.deinit(gpa);
    self.flow.deinit(gpa);
    self.flow_queue.deinit(gpa);
}

pub fn clear(self: *Navmesh, gpa: std.mem.Allocator) void {
    for (self.chunks.values()) |*chunk| chunk.node_map.deinit(gpa);
    self.chunks.clearRetainingCapacity();
    self.flow.clearRetainingCapacity();
}

fn nodeCentroid(self: *Navmesh, cell: nz.Vec3(i32)) ?nz.Vec3(f32) {
    const chunk_position = @divFloor(cell, @as(nz.Vec3(i32), @splat(shared.planet.Chunk.dim)));
    const chunk = self.chunks.getPtr(chunk_position) orelse return null;
    return chunk.node_map.get(cell);
}

pub fn buildFlow(self: *Navmesh, player_positions: []const nz.Vec3(f32)) void {
    self.flow.clearRetainingCapacity();
    self.flow_queue.clearRetainingCapacity();
    for (player_positions) |position| {
        const center: nz.Vec3(i32) = @intFromFloat(@floor(position));
        var seed_cell: ?nz.Vec3(i32) = null;
        var seed_distance: f32 = std.math.floatMax(f32);
        if (self.nodeCentroid(center)) |centroid| {
            seed_cell = center;
            seed_distance = nz.vec.distance(centroid, position);
        }
        for (neighbor_offsets) |offset| {
            const cell = center + offset;
            const centroid = self.nodeCentroid(cell) orelse continue;
            const cell_distance = nz.vec.distance(centroid, position);
            if (cell_distance < seed_distance) {
                seed_distance = cell_distance;
                seed_cell = cell;
            }
        }
        const seed = seed_cell orelse continue;
        if (self.flow.contains(seed)) continue;
        if (self.flow.count() >= max_flow_nodes) return;
        self.flow.putAssumeCapacity(seed, .{ .centroid = self.nodeCentroid(seed).?, .distance = 0 });
        self.flow_queue.appendAssumeCapacity(seed);
    }
    var head: usize = 0;
    while (head < self.flow_queue.items.len) : (head += 1) {
        const cell = self.flow_queue.items[head];
        const cell_distance = self.flow.get(cell).?.distance;
        for (neighbor_offsets) |offset| {
            const neighbor = cell + offset;
            if (self.flow.contains(neighbor)) continue;
            const neighbor_centroid = self.nodeCentroid(neighbor) orelse continue;
            if (self.flow.count() >= max_flow_nodes) return;
            self.flow.putAssumeCapacity(neighbor, .{ .centroid = neighbor_centroid, .distance = cell_distance + 1 });
            self.flow_queue.appendAssumeCapacity(neighbor);
        }
    }
}

pub fn flowAt(self: *Navmesh, position: nz.Vec3(f32)) ?nz.Vec3(f32) {
    const center: nz.Vec3(i32) = @intFromFloat(@floor(position));
    var best_target: ?nz.Vec3(f32) = null;
    var best_distance: u16 = std.math.maxInt(u16);
    if (self.flow.get(center)) |own| best_distance = own.distance;
    for (neighbor_offsets) |offset| {
        const flow_node = self.flow.get(center + offset) orelse continue;
        if (flow_node.distance < best_distance) {
            best_distance = flow_node.distance;
            best_target = flow_node.centroid;
        }
    }
    return best_target;
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
