const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const planet = @import("root.zig");

pub const dim: i32 = 32;

pub const CellRegion = struct {
    min: nz.Vec3(i32),
    max: nz.Vec3(i32),

    fn contains(self: CellRegion, cell: nz.Vec3(i32)) bool {
        return @reduce(.And, cell >= self.min) and @reduce(.And, cell < self.max);
    }
};

const quad_axes = [3]struct { edge_axis: nz.Vec3(i32), perp_b: nz.Vec3(i32), perp_c: nz.Vec3(i32) }{
    .{ .edge_axis = .{ 1, 0, 0 }, .perp_b = .{ 0, 1, 0 }, .perp_c = .{ 0, 0, 1 } },
    .{ .edge_axis = .{ 0, 1, 0 }, .perp_b = .{ 0, 0, 1 }, .perp_c = .{ 1, 0, 0 } },
    .{ .edge_axis = .{ 0, 0, 1 }, .perp_b = .{ 1, 0, 0 }, .perp_c = .{ 0, 1, 0 } },
};

pub const Kind = enum {
    mesh,
    navmesh,
};

pub fn Product(kind: Kind) type {
    return switch (kind) {
        .mesh => Mesh,
        .navmesh => NavGraph,
    };
}

pub fn generate(comptime kind: Kind, gpa: std.mem.Allocator, raw: *const Raw, planet_radius: u32) !Product(kind) {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const owned: CellRegion = .{ .min = min(raw.coord), .max = max(raw.coord) };
    const radius_float: f32 = @floatFromInt(planet_radius);

    var mesh_vertices: std.ArrayList(Mesh.Vertex) = .empty;
    var mesh_indices: std.ArrayList(u32) = .empty;
    errdefer if (kind == .mesh) {
        mesh_vertices.deinit(gpa);
        mesh_indices.deinit(gpa);
    };
    var nav: NavGraph = if (kind == .navmesh) try NavGraph.prepare(gpa, raw, owned) else undefined;
    errdefer if (kind == .navmesh) nav.deinit(gpa);

    for (raw.node_map.keys()) |anchor| {
        if (kind == .mesh and !owned.contains(anchor)) continue;
        for (quad_axes) |quad_axis| {
            const edge_start_solid = raw.density.isSolidAt(anchor);
            const edge_end_solid = raw.density.isSolidAt(anchor + quad_axis.edge_axis);
            if (edge_start_solid == edge_end_solid) continue;

            const corner_b = anchor - quad_axis.perp_b;
            const corner_c = anchor - quad_axis.perp_c;
            const corner_bc = anchor - quad_axis.perp_b - quad_axis.perp_c;
            const index_b = raw.node_map.getIndex(corner_b) orelse continue;
            const index_c = raw.node_map.getIndex(corner_c) orelse continue;
            const index_bc = raw.node_map.getIndex(corner_bc) orelse continue;

            switch (kind) {
                .mesh => {
                    const index_anchor = raw.node_map.getIndex(anchor).?;
                    const centroids = raw.node_map.values();
                    const base_vertex_index: u32 = @intCast(mesh_vertices.items.len);
                    try mesh_vertices.append(gpa, makeVertex(centroids[index_anchor], .{ 0, 0 }, radius_float));
                    try mesh_vertices.append(gpa, makeVertex(centroids[index_b], .{ 1, 0 }, radius_float));
                    try mesh_vertices.append(gpa, makeVertex(centroids[index_c], .{ 0, 1 }, radius_float));
                    try mesh_vertices.append(gpa, makeVertex(centroids[index_bc], .{ 1, 1 }, radius_float));

                    if (edge_start_solid) {
                        try mesh_indices.appendSlice(gpa, &.{ base_vertex_index + 0, base_vertex_index + 1, base_vertex_index + 3, base_vertex_index + 0, base_vertex_index + 3, base_vertex_index + 2 });
                    } else {
                        try mesh_indices.appendSlice(gpa, &.{ base_vertex_index + 0, base_vertex_index + 3, base_vertex_index + 1, base_vertex_index + 0, base_vertex_index + 2, base_vertex_index + 3 });
                    }
                },
                .navmesh => {
                    nav.link(raw, anchor, corner_b);
                    nav.link(raw, anchor, corner_c);
                    nav.link(raw, anchor, corner_bc);
                    nav.link(raw, corner_b, corner_bc);
                    nav.link(raw, corner_c, corner_bc);
                },
            }
        }
    }

    switch (kind) {
        .mesh => {
            const owned_vertices = try mesh_vertices.toOwnedSlice(gpa);
            errdefer gpa.free(owned_vertices);
            const owned_indices = try mesh_indices.toOwnedSlice(gpa);
            return .{ .vertices = owned_vertices, .indices = owned_indices };
        },
        .navmesh => return nav,
    }
}

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,

    pub const Vertex = @import("../vertex.zig").StaticVertex;

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
    }
};

fn makeVertex(position: nz.Vec3(f32), uv: [2]f32, planet_radius: f32) Mesh.Vertex {
    const height = nz.vec.length(position);
    const height_fraction = std.math.clamp((height - planet_radius) / 30, 0, 1);
    const low_color: nz.Vec3(f32) = .{ 1, 0.35, 0.2 };
    const high_color: nz.Vec3(f32) = .{ 0.1, 0.75, 0.6 };
    const color = nz.vec.scale(low_color, 1 - height_fraction) + nz.vec.scale(high_color, height_fraction);
    return .{
        .position = position,
        .normal = nz.vec.normalize(sdf.gradient(position, planet_radius)),
        .color = .{ color[0], color[1], color[2], 1 },
        .uv_x = uv[0],
        .uv_y = uv[1],
    };
}

pub const NavGraph = struct {
    cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
    neighbors: []Neighbor,
    weights: []f32,

    pub const Neighbor = enum(u16) {
        boundary_edge = 0xFFFE,
        none = 0xFFFF,
        _,
    };

    pub const max_neighbor_count: usize = 12;

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

    pub const neighbor_offsets = [max_neighbor_count]nz.Vec3(i32){
        .{ 1, 0, 0 }, .{ -1, 0, 0 },  .{ 0, 1, 0 }, .{ 0, -1, 0 },
        .{ 0, 0, 1 }, .{ 0, 0, -1 },  .{ 1, 1, 0 }, .{ -1, -1, 0 },
        .{ 0, 1, 1 }, .{ 0, -1, -1 }, .{ 1, 0, 1 }, .{ -1, 0, -1 },
    };

    fn prepare(gpa: std.mem.Allocator, raw: *const Raw, owned: CellRegion) !NavGraph {
        var cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
        errdefer cells.deinit(gpa);
        for (raw.node_map.keys(), raw.node_map.values()) |cell, position| {
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

    pub fn deinit(self: *NavGraph, gpa: std.mem.Allocator) void {
        self.cells.deinit(gpa);
        gpa.free(self.neighbors);
        gpa.free(self.weights);
    }

    fn link(self: *NavGraph, raw: *const Raw, cell_a: nz.Vec3(i32), cell_b: nz.Vec3(i32)) void {
        self.linkDirected(raw, cell_a, cell_b);
        self.linkDirected(raw, cell_b, cell_a);
    }

    fn linkDirected(self: *NavGraph, raw: *const Raw, from_cell: nz.Vec3(i32), to_cell: nz.Vec3(i32)) void {
        const from_index = self.cells.getIndex(from_cell) orelse return;
        const offset = to_cell - from_cell;
        const slot = for (neighbor_offsets, 0..) |candidate, candidate_slot| {
            if (@reduce(.And, candidate == offset)) break candidate_slot;
        } else unreachable;
        const entry_index = from_index * max_neighbor_count + slot;
        if (self.neighbors[entry_index] != .none) return;
        const from_position = self.cells.values()[from_index];
        const to_position = raw.node_map.get(to_cell).?;
        const step = from_position - to_position;
        const distance = nz.vec.length(step);
        const slope = nz.vec.dot(nz.vec.scale(step, 1.0 / distance), nz.vec.normalize(to_position));
        self.neighbors[entry_index] = if (self.cells.getIndex(to_cell)) |to_index| @enumFromInt(to_index) else .boundary_edge;
        self.weights[entry_index] = distance * (1 + @max(0, slope));
    }
};

pub const Range = struct { min: i32, max: i32 };

pub const Coord = struct {
    position: nz.Vec3(i32),

    pub fn fromPosition(position: nz.Vec3(f32)) Coord {
        return .{ .position = @intFromFloat(@floor(position / @as(nz.Vec3(f32), @splat(@floatFromInt(dim))))) };
    }

    pub fn offset(self: Coord, delta: nz.Vec3(i32)) Coord {
        return .{ .position = self.position + delta };
    }

    pub fn eql(self: Coord, other: Coord) bool {
        return @reduce(.And, self.position == other.position);
    }

    pub fn within(self: Coord, center: Coord, reach: i32) bool {
        const difference = self.position - center.position;
        return @reduce(.And, difference >= @as(nz.Vec3(i32), @splat(-reach))) and @reduce(.And, difference <= @as(nz.Vec3(i32), @splat(reach)));
    }
};

pub const Box = struct { min: Coord, max: Coord };

pub const Raw = struct {
    node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
    density: sdf.DensityGrid,
    coord: Coord,

    pub fn init(gpa: std.mem.Allocator, planet_radius: u32, chunk: Coord) !Raw {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const radius_float: f32 = @floatFromInt(planet_radius);
        const cell_min = min(chunk);
        const cell_max = max(chunk);
        const apron_min = cell_min - @as(nz.Vec3(i32), @splat(1));
        const apron_max = cell_max + @as(nz.Vec3(i32), @splat(1));

        var density = try sdf.DensityGrid.initRegion(gpa, radius_float, apron_min, apron_max);
        errdefer density.deinit(gpa);

        var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
        errdefer node_map.deinit(gpa);
        try sdf.surface_nodes.buildRegion(gpa, &node_map, &density, apron_min, apron_max);

        return .{ .node_map = node_map, .density = density, .coord = chunk };
    }

    pub fn deinit(self: *Raw, gpa: std.mem.Allocator) void {
        self.node_map.deinit(gpa);
        self.density.deinit(gpa);
    }
};

pub fn coords(gpa: std.mem.Allocator, planet_radius: u32, clamp: ?Box) ![]Coord {
    var chunks: std.ArrayList(Coord) = .empty;
    errdefer chunks.deinit(gpa);
    const chunk_span = range(planet_radius);
    var span_min: nz.Vec3(i32) = @splat(chunk_span.min);
    var span_max: nz.Vec3(i32) = @splat(chunk_span.max);
    if (clamp) |box| {
        span_min = @max(span_min, box.min.position);
        span_max = @min(span_max, box.max.position);
    }
    const surface_reach: f32 = @floatFromInt(planet_radius + sdf.noise_amplitude + planet.cell_margin);
    const surface_reach_squared = surface_reach * surface_reach;
    const solid_depth: f32 = @floatFromInt(planet_radius - @min(planet_radius, sdf.noise_amplitude + planet.cell_margin));
    const solid_depth_squared = solid_depth * solid_depth;
    var x = span_min[0];
    while (x <= span_max[0]) : (x += 1) {
        var y = span_min[1];
        while (y <= span_max[1]) : (y += 1) {
            var z = span_min[2];
            while (z <= span_max[2]) : (z += 1) {
                const chunk: Coord = .{ .position = .{ x, y, z } };
                const box_min: nz.Vec3(f32) = @floatFromInt(min(chunk));
                const box_max: nz.Vec3(f32) = @floatFromInt(max(chunk));
                const chunk_nearest_point_to_planet = @max(box_min, @min(box_max, @as(nz.Vec3(f32), @splat(0))));
                if (nz.vec.dot(chunk_nearest_point_to_planet, chunk_nearest_point_to_planet) > surface_reach_squared) continue;
                // TODO: (CAVES): DELETE THIS SKIP when caves carve the sdf!
                // It assumes fully-buried chunks are solid rock with no surface.
                // The day sdf() subtracts caves, buried chunks can contain geometry
                // and this check will silently produce holes in the world.
                const chunk_farthest_point_to_planet = @max(@abs(box_min), @abs(box_max));
                if (nz.vec.dot(chunk_farthest_point_to_planet, chunk_farthest_point_to_planet) < solid_depth_squared) continue;
                try chunks.append(gpa, chunk);
            }
        }
    }
    return chunks.toOwnedSlice(gpa);
}

pub fn min(chunk: Coord) nz.Vec3(i32) {
    return chunk.position * @as(nz.Vec3(i32), @splat(dim));
}

pub fn max(chunk: Coord) nz.Vec3(i32) {
    return min(chunk) + @as(nz.Vec3(i32), @splat(dim));
}

pub fn range(planet_radius: u32) Range {
    const bound: i32 = @intCast(planet_radius + sdf.noise_amplitude + planet.cell_margin);
    return .{
        .min = @divFloor(-bound, dim),
        .max = @divFloor(bound, dim),
    };
}

test "chunk coordinates cover dim cells" {
    const chunk: Coord = .{ .position = .{ -2, 3, 0 } };
    try std.testing.expectEqual(nz.Vec3(i32){ -64, 96, 0 }, min(chunk));
    try std.testing.expectEqual(nz.Vec3(i32){ -32, 128, 32 }, max(chunk));
}

test "chunk range contains the complete planet density field" {
    try std.testing.expectEqual(Range{ .min = -1, .max = 0 }, range(18));
    try std.testing.expectEqual(Range{ .min = -3, .max = 2 }, range(67));
}

test "chunk coords respect the clamp box" {
    const box: Box = .{ .min = .{ .position = .{ 0, 0, 0 } }, .max = .{ .position = .{ 1, 1, 1 } } };
    const chunks = try coords(std.testing.allocator, 67, box);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len > 0);
    for (chunks) |chunk| {
        try std.testing.expect(@reduce(.And, chunk.position >= box.min.position));
        try std.testing.expect(@reduce(.And, chunk.position <= box.max.position));
    }
}

pub const Job = struct {
    thread: std.Thread,
    state: *State,

    pub const Result = struct {
        coord: Coord,
        raw: Raw,
        vertices: []Mesh.Vertex,
        indices: []u32,
        nav: NavGraph,
    };

    pub const State = struct {
        gpa: std.mem.Allocator,
        planet_radius: u32,
        coords: []Coord,
        results: std.ArrayList(Result),
        done: std.atomic.Value(bool),
    };

    pub fn start(gpa: std.mem.Allocator, planet_radius: u32, job_coords: []Coord) !@This() {
        errdefer gpa.free(job_coords);
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{ .gpa = gpa, .planet_radius = planet_radius, .coords = job_coords, .results = .empty, .done = .init(false) };
        return .{ .thread = try std.Thread.spawn(.{}, run, .{state}), .state = state };
    }

    pub fn collect(self: @This()) ?std.ArrayList(Result) {
        if (!self.state.done.load(.acquire)) return null;
        self.thread.join();
        const results = self.state.results;
        self.state.gpa.free(self.state.coords);
        self.state.gpa.destroy(self.state);
        return results;
    }

    pub fn join(self: @This()) void {
        self.thread.join();
        for (self.state.results.items) |*result| {
            result.raw.deinit(self.state.gpa);
            self.state.gpa.free(result.vertices);
            self.state.gpa.free(result.indices);
            result.nav.deinit(self.state.gpa);
        }
        self.state.results.deinit(self.state.gpa);
        self.state.gpa.free(self.state.coords);
        self.state.gpa.destroy(self.state);
    }

    fn run(state: *State) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        for (state.coords) |coord| {
            var raw = Raw.init(state.gpa, state.planet_radius, coord) catch continue;
            const chunk_mesh = generate(.mesh, state.gpa, &raw, state.planet_radius) catch {
                raw.deinit(state.gpa);
                continue;
            };
            var nav = generate(.navmesh, state.gpa, &raw, state.planet_radius) catch {
                raw.deinit(state.gpa);
                chunk_mesh.deinit(state.gpa);
                continue;
            };
            state.results.append(state.gpa, .{ .coord = coord, .raw = raw, .vertices = chunk_mesh.vertices, .indices = chunk_mesh.indices, .nav = nav }) catch {
                raw.deinit(state.gpa);
                chunk_mesh.deinit(state.gpa);
                nav.deinit(state.gpa);
            };
        }
        state.done.store(true, .release);
    }
};
