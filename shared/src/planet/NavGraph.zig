const NavGraph = @This();

const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const Chunk = @import("Chunk.zig");

cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
neighbors: []Neighbor,
weights: []f32,

pub const Neighbor = enum(u16) {
    boundary_edge = 0xFFFE,
    none = 0xFFFF,
    _,
};

pub const max_neighbor_count: usize = 12;

const max_walkable_slope: f32 = 0.6;

pub const neighbor_offsets = [max_neighbor_count]nz.Vec3(i32){
    .{ 1, 0, 0 }, .{ -1, 0, 0 },  .{ 0, 1, 0 }, .{ 0, -1, 0 },
    .{ 0, 0, 1 }, .{ 0, 0, -1 },  .{ 1, 1, 0 }, .{ -1, -1, 0 },
    .{ 0, 1, 1 }, .{ 0, -1, -1 }, .{ 1, 0, 1 }, .{ -1, 0, -1 },
};

pub fn generate(gpa: std.mem.Allocator, chunk: *const Chunk) !NavGraph {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const owned: Chunk.CellRegion = .{ .min = Chunk.min(chunk.coord), .max = Chunk.max(chunk.coord) };

    var nav_graph: NavGraph = try prepare(gpa, chunk, owned);
    errdefer nav_graph.deinit(gpa);

    for (chunk.surface_cells.keys()) |anchor| {
        for (Chunk.quad_axes) |quad_axis| {
            const edge_start_solid = chunk.density.isSolidAt(anchor);
            const edge_end_solid = chunk.density.isSolidAt(anchor + quad_axis.edge_axis);
            if (edge_start_solid == edge_end_solid) continue;

            const corner_b = anchor - quad_axis.perp_b;
            const corner_c = anchor - quad_axis.perp_c;
            const corner_bc = anchor - quad_axis.perp_b - quad_axis.perp_c;
            if (chunk.surface_cells.getIndex(corner_b) == null) continue;
            if (chunk.surface_cells.getIndex(corner_c) == null) continue;
            if (chunk.surface_cells.getIndex(corner_bc) == null) continue;

            nav_graph.link(chunk, anchor, corner_b);
            nav_graph.link(chunk, anchor, corner_c);
            nav_graph.link(chunk, anchor, corner_bc);
            nav_graph.link(chunk, corner_b, corner_bc);
            nav_graph.link(chunk, corner_c, corner_bc);
        }
    }

    return nav_graph;
}

pub fn deinit(self: *NavGraph, gpa: std.mem.Allocator) void {
    self.cells.deinit(gpa);
    gpa.free(self.neighbors);
    gpa.free(self.weights);
}

pub fn neighborCell(self: *const NavGraph, index: usize, slot: usize) nz.Vec3(i32) {
    return self.cells.keys()[index] + neighbor_offsets[slot];
}

pub fn clone(self: *const NavGraph, gpa: std.mem.Allocator) !NavGraph {
    var cells = try self.cells.clone(gpa);
    errdefer cells.deinit(gpa);
    const neighbors = try gpa.dupe(Neighbor, self.neighbors);
    errdefer gpa.free(neighbors);
    return .{ .cells = cells, .neighbors = neighbors, .weights = try gpa.dupe(f32, self.weights) };
}

fn prepare(gpa: std.mem.Allocator, chunk: *const Chunk, owned: Chunk.CellRegion) !NavGraph {
    var cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
    errdefer cells.deinit(gpa);
    for (chunk.surface_cells.keys(), chunk.surface_cells.values()) |cell, position| {
        if (owned.contains(cell)) try cells.put(gpa, cell, position);
    }
    const node_count = cells.count();
    const neighbors = try gpa.alloc(Neighbor, node_count * max_neighbor_count);
    errdefer gpa.free(neighbors);
    @memset(neighbors, .none);
    const weights = try gpa.alloc(f32, node_count * max_neighbor_count);
    errdefer gpa.free(weights);
    @memset(weights, 0);

    return .{ .cells = cells, .neighbors = neighbors, .weights = weights };
}

fn link(self: *NavGraph, chunk: *const Chunk, cell_a: nz.Vec3(i32), cell_b: nz.Vec3(i32)) void {
    self.linkDirected(chunk, cell_a, cell_b);
    self.linkDirected(chunk, cell_b, cell_a);
}

fn linkDirected(self: *NavGraph, chunk: *const Chunk, from_cell: nz.Vec3(i32), to_cell: nz.Vec3(i32)) void {
    const from_index = self.cells.getIndex(from_cell) orelse return;
    const offset = to_cell - from_cell;
    const slot = for (neighbor_offsets, 0..) |candidate, candidate_slot| {
        if (@reduce(.And, candidate == offset)) break candidate_slot;
    } else unreachable;
    const entry_index = from_index * max_neighbor_count + slot;
    if (self.neighbors[entry_index] != .none) return;
    const from_position = self.cells.values()[from_index];
    const to_position = chunk.surface_cells.get(to_cell).?;
    const step = from_position - to_position;
    const distance = nz.vec.length(step);
    const slope = nz.vec.dot(nz.vec.scale(step, 1.0 / distance), nz.vec.normalize(to_position));
    self.neighbors[entry_index] = if (self.cells.getIndex(to_cell)) |to_index| @enumFromInt(to_index) else .boundary_edge;
    const steep_penalty: f32 = if (slope > max_walkable_slope) 50 else 1;
    self.weights[entry_index] = distance * (1 + @max(0, slope)) * steep_penalty;
}
