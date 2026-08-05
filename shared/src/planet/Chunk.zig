const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const planet = @import("root.zig");

pub const dim: i32 = 32;

pub const MeshKind = enum {
    logical,
    renderable,
};

pub fn Mesh(kind: MeshKind) type {
    return struct {
        vertices: []Vertex,
        indices: []u32,

        const CellRegion = struct {
            min: nz.Vec3(i32),
            max: nz.Vec3(i32),

            fn contains(self: CellRegion, cell: nz.Vec3(i32)) bool {
                return @reduce(.And, cell >= self.min) and @reduce(.And, cell < self.max);
            }
        };

        pub const Vertex = switch (kind) {
            .logical => [4]f32,
            .renderable => @import("../vertex.zig").StaticVertex,
        };

        pub fn init(gpa: std.mem.Allocator, planet_radius: u32) !@This() {
            const radius_float: f32 = @floatFromInt(planet_radius);

            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            const bound: f32 = @ceil(radius_float + sdf.noise_amplitude + planet.cell_margin);
            var density = try sdf.DensityGrid.init(gpa, radius_float, bound);
            defer density.deinit(gpa);

            try sdf.surface_nodes.build(gpa, &node_map, &density, radius_float, bound);

            return try buildMesh(gpa, &node_map, &density, radius_float, null);
        }

        pub fn generate(gpa: std.mem.Allocator, raw: *const Raw, planet_radius: u32) !@This() {
            return try buildMesh(gpa, &raw.node_map, &raw.density, @floatFromInt(planet_radius), .{ .min = min(raw.coord), .max = max(raw.coord) });
        }

        fn buildMesh(gpa: std.mem.Allocator, node_map: *const std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const sdf.DensityGrid, planet_radius: f32, owned_region: ?CellRegion) !@This() {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            var vertices: std.ArrayList(Vertex) = .empty;
            var indices: std.ArrayList(u32) = .empty;

            if (kind == .logical) {
                for (node_map.values()) |centroid|
                    try vertices.append(gpa, .{ centroid[0], centroid[1], centroid[2], 1 });
            }

            const quad_axes = [3]struct { edge_axis: nz.Vec3(i32), perp_b: nz.Vec3(i32), perp_c: nz.Vec3(i32) }{
                .{ .edge_axis = .{ 1, 0, 0 }, .perp_b = .{ 0, 1, 0 }, .perp_c = .{ 0, 0, 1 } },
                .{ .edge_axis = .{ 0, 1, 0 }, .perp_b = .{ 0, 0, 1 }, .perp_c = .{ 1, 0, 0 } },
                .{ .edge_axis = .{ 0, 0, 1 }, .perp_b = .{ 1, 0, 0 }, .perp_c = .{ 0, 1, 0 } },
            };
            for (node_map.keys()) |cell| {
                if (owned_region) |region| if (!region.contains(cell)) continue;
                for (quad_axes) |quad_axis| {
                    const edge_start_solid = density.isSolidAt(cell);
                    const edge_end_solid = density.isSolidAt(cell + quad_axis.edge_axis);
                    if (edge_start_solid == edge_end_solid) continue;

                    const index_at_cell: u32 = @intCast(node_map.getIndex(cell) orelse continue);
                    const index_minus_b: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_b) orelse continue);
                    const index_minus_c: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_c) orelse continue);
                    const index_minus_bc: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_b - quad_axis.perp_c) orelse continue);

                    switch (kind) {
                        .renderable => {
                            const centroids = node_map.values();
                            const base_vertex_index: u32 = @intCast(vertices.items.len);
                            try vertices.append(gpa, makeVertex(centroids[index_at_cell], .{ 0, 0 }, planet_radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_b], .{ 1, 0 }, planet_radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_c], .{ 0, 1 }, planet_radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_bc], .{ 1, 1 }, planet_radius));

                            if (edge_start_solid) {
                                try indices.appendSlice(gpa, &.{ base_vertex_index + 0, base_vertex_index + 1, base_vertex_index + 3, base_vertex_index + 0, base_vertex_index + 3, base_vertex_index + 2 });
                            } else {
                                try indices.appendSlice(gpa, &.{ base_vertex_index + 0, base_vertex_index + 3, base_vertex_index + 1, base_vertex_index + 0, base_vertex_index + 2, base_vertex_index + 3 });
                            }
                        },
                        .logical => {
                            if (edge_start_solid)
                                try indices.appendSlice(gpa, &.{ index_at_cell, index_minus_b, index_minus_bc, index_at_cell, index_minus_bc, index_minus_c })
                            else
                                try indices.appendSlice(gpa, &.{ index_at_cell, index_minus_bc, index_minus_b, index_at_cell, index_minus_c, index_minus_bc });
                        },
                    }
                }
            }

            const owned_vertices = try vertices.toOwnedSlice(gpa);
            errdefer gpa.free(owned_vertices);
            const owned_indices = try indices.toOwnedSlice(gpa);
            return .{
                .vertices = owned_vertices,
                .indices = owned_indices,
            };
        }

        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            gpa.free(self.vertices);
            gpa.free(self.indices);
        }

        fn makeVertex(position: nz.Vec3(f32), uv: [2]f32, planet_radius: f32) Vertex {
            return switch (kind) {
                .logical => .{ position[0], position[1], position[2], 1 },
                .renderable => blk: {
                    const height = nz.vec.length(position);
                    const height_fraction = std.math.clamp((height - planet_radius) / 30, 0, 1);
                    const low_color: nz.Vec3(f32) = .{ 1, 0.35, 0.2 };
                    const high_color: nz.Vec3(f32) = .{ 0.1, 0.75, 0.6 };
                    const color = nz.vec.scale(low_color, 1 - height_fraction) + nz.vec.scale(high_color, height_fraction);
                    break :blk .{
                        .position = position,
                        .normal = nz.vec.normalize(sdf.gradient(position, planet_radius)),
                        .color = .{ color[0], color[1], color[2], 1 },
                        .uv_x = uv[0],
                        .uv_y = uv[1],
                    };
                },
            };
        }
    };
}

test "a surface chunk builds logical nodes" {
    const chunk: Coord = .{ .position = .{ 0, 0, 0 } };
    var raw = try Raw.init(std.testing.allocator, 18, chunk);
    defer raw.deinit(std.testing.allocator);
    const logical_mesh = try Mesh(.logical).generate(std.testing.allocator, &raw, 18);
    defer logical_mesh.deinit(std.testing.allocator);
    try std.testing.expect(logical_mesh.vertices.len > 0);
}

test "tiled chunks emit the monolith's surface index count" {
    const planet_radius = 18;
    const monolith = try Mesh(.renderable).init(std.testing.allocator, planet_radius);
    defer monolith.deinit(std.testing.allocator);

    var chunk_index_count: usize = 0;
    const chunk_span = range(planet_radius);
    var x = chunk_span.min;
    while (x <= chunk_span.max) : (x += 1) {
        var y = chunk_span.min;
        while (y <= chunk_span.max) : (y += 1) {
            var z = chunk_span.min;
            while (z <= chunk_span.max) : (z += 1) {
                var raw = try Raw.init(std.testing.allocator, planet_radius, .{ .position = .{ x, y, z } });
                defer raw.deinit(std.testing.allocator);
                const chunk_mesh = try Mesh(.renderable).generate(std.testing.allocator, &raw, planet_radius);
                defer chunk_mesh.deinit(std.testing.allocator);
                chunk_index_count += chunk_mesh.indices.len;
            }
        }
    }
    try std.testing.expectEqual(monolith.indices.len, chunk_index_count);
}

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

        var density = try sdf.DensityGrid.initRegion(gpa, radius_float, apron_min, cell_max);
        errdefer density.deinit(gpa);

        var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
        errdefer node_map.deinit(gpa);
        try sdf.surface_nodes.buildRegion(gpa, &node_map, &density, apron_min, cell_max);

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

pub fn Job(comptime kind: MeshKind) type {
    return struct {
        thread: std.Thread,
        state: *State,

        pub const Result = struct {
            coord: Coord,
            raw: Raw,
            vertices: []Mesh(kind).Vertex,
            indices: []u32,
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
            return .{ .thread = try std.Thread.spawn(.{}, generate, .{state}), .state = state };
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
            }
            self.state.results.deinit(self.state.gpa);
            self.state.gpa.free(self.state.coords);
            self.state.gpa.destroy(self.state);
        }

        fn generate(state: *State) void {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            for (state.coords) |coord| {
                var raw = Raw.init(state.gpa, state.planet_radius, coord) catch continue;
                const chunk_mesh = Mesh(kind).generate(state.gpa, &raw, state.planet_radius) catch {
                    raw.deinit(state.gpa);
                    continue;
                };
                state.results.append(state.gpa, .{ .coord = coord, .raw = raw, .vertices = chunk_mesh.vertices, .indices = chunk_mesh.indices }) catch {
                    raw.deinit(state.gpa);
                    chunk_mesh.deinit(state.gpa);
                };
            }
            state.done.store(true, .release);
        }
    };
}
