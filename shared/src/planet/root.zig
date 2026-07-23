const std = @import("std");
const nz = @import("numz");
pub const sdf = @import("sdf.zig");
const tracy = @import("ztracy");

pub const cell_margin = 1;

pub const Chunk = @import("Chunk.zig");

pub const min_radius: u32 = 20;
pub const radius_max: u32 = 80;
pub const dev_radius_min: u32 = 1000;
pub const dev_radius_max: u32 = 1100;

pub const PlanetKind = enum {
    logical,
    renderable,
};

pub fn Planet(kind: PlanetKind) type {
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

        pub fn init(gpa: std.mem.Allocator, radius: u32) !@This() {
            const radius_float: f32 = @floatFromInt(radius);

            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            const bound: f32 = @ceil(radius_float + sdf.noise_amplitude + cell_margin);
            var density = try sdf.DensityGrid.init(gpa, radius_float, bound);
            defer density.deinit(gpa);

            try sdf.surface_nodes.build(gpa, &node_map, &density, radius_float, bound);

            return try buildMesh(gpa, &node_map, &density, radius_float, null);
        }

        pub fn initChunk(gpa: std.mem.Allocator, radius: u32, chunk: Chunk.Coord) !@This() {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            const radius_float: f32 = @floatFromInt(radius);
            const cell_min = Chunk.min(chunk);
            const cell_max = Chunk.max(chunk);
            const apron_min = cell_min - @as(nz.Vec3(i32), @splat(1));

            var density = try sdf.DensityGrid.initRegion(gpa, radius_float, apron_min, cell_max);
            defer density.deinit(gpa);

            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            try sdf.surface_nodes.buildRegion(gpa, &node_map, &density, apron_min, cell_max);

            return try buildMesh(gpa, &node_map, &density, radius_float, .{ .min = cell_min, .max = cell_max });
        }

        fn buildMesh(gpa: std.mem.Allocator, node_map: *const std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const sdf.DensityGrid, radius: f32, owned_region: ?CellRegion) !@This() {
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
                            try vertices.append(gpa, makeVertex(centroids[index_at_cell], .{ 0, 0 }, radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_b], .{ 1, 0 }, radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_c], .{ 0, 1 }, radius));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_bc], .{ 1, 1 }, radius));

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

        fn makeVertex(position: nz.Vec3(f32), uv: [2]f32, radius: f32) Vertex {
            //logical planet: build navmesh nodes from node_map (reuse the cells + neighbours), don't generate triangles like renderable
            return switch (kind) {
                .logical => .{ position[0], position[1], position[2], 1 },
                .renderable => blk: {
                    const height = nz.vec.length(position);
                    const height_fraction = std.math.clamp((height - radius) / 30, 0, 1);
                    const low_color: nz.Vec3(f32) = .{ 1, 0.35, 0.2 };
                    const high_color: nz.Vec3(f32) = .{ 0.1, 0.75, 0.6 };
                    const color = nz.vec.scale(low_color, 1 - height_fraction) + nz.vec.scale(high_color, height_fraction);
                    break :blk .{
                        .position = position,
                        .normal = nz.vec.normalize(position),
                        .color = .{ color[0], color[1], color[2], 1 },
                        .uv_x = uv[0],
                        .uv_y = uv[1],
                    };
                },
            };
        }
    };
}

pub fn up(position: nz.Vec3(f32)) ?nz.Vec3(f32) {
    const distance = nz.vec.length(position);
    return if (distance > 0.001) nz.vec.scale(position, 1.0 / distance) else null;
}

pub fn surfaceLaunch(position: nz.Vec3(f32), direction: nz.Vec3(f32), angle: f32, speed: f32) nz.Vec3(f32) {
    const surface_up = up(position) orelse nz.Vec3(f32){ 0, 1, 0 };
    const flat_direction = direction - nz.vec.scale(surface_up, nz.vec.dot(direction, surface_up));
    const heading = if (nz.vec.length(flat_direction) > 0.001)
        nz.vec.normalize(flat_direction)
    else heading: {
        const helper: nz.Vec3(f32) = if (@abs(surface_up[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        break :heading nz.vec.normalize(nz.vec.cross(surface_up, helper));
    };
    const launch = nz.vec.scale(heading, @cos(angle)) + nz.vec.scale(surface_up, @sin(angle));
    return nz.vec.scale(launch, speed);
}

pub fn surfaceTransform(direction: nz.Vec3(f32), radius: f32, hover: f32) nz.Transform3D(f32) {
    const surface = surfacePoint(direction, radius);
    const surface_up = up(surface) orelse nz.Vec3(f32){ 0, 1, 0 };
    const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
    const dot = std.math.clamp(nz.vec.dot(default_up, surface_up), -1.0, 1.0);
    const rotation: nz.quat.Hamiltonian(f32) = if (dot >= 0.9999) .identity else rot: {
        const axis = if (dot > -0.9999)
            nz.vec.normalize(nz.vec.cross(default_up, surface_up))
        else
            nz.Vec3(f32){ 1, 0, 0 };
        break :rot .angleAxis(std.math.acos(dot), axis);
    };
    return .{
        .position = surface + nz.vec.scale(surface_up, hover),
        .rotation = rotation,
    };
}

test "a surface chunk builds logical nodes" {
    const chunk: Chunk.Coord = .{ .position = .{ 0, 0, 0 } };
    const planet = try Planet(.logical).initChunk(std.testing.allocator, 18, chunk);
    defer planet.deinit(std.testing.allocator);
    try std.testing.expect(planet.vertices.len > 0);
}

test "tiled chunks emit the monolith's surface index count" {
    const radius = 18;
    const monolith = try Planet(.renderable).init(std.testing.allocator, radius);
    defer monolith.deinit(std.testing.allocator);

    var chunk_index_count: usize = 0;
    const range = Chunk.range(radius);
    var x = range.min;
    while (x <= range.max) : (x += 1) {
        var y = range.min;
        while (y <= range.max) : (y += 1) {
            var z = range.min;
            while (z <= range.max) : (z += 1) {
                const chunk = try Planet(.renderable).initChunk(std.testing.allocator, radius, .{ .position = .{ x, y, z } });
                defer chunk.deinit(std.testing.allocator);
                chunk_index_count += chunk.indices.len;
            }
        }
    }
    try std.testing.expectEqual(monolith.indices.len, chunk_index_count);
}

pub fn surfacePoint(direction: nz.Vec3(f32), radius: f32) nz.Vec3(f32) {
    const unit_direction = nz.vec.normalize(direction);
    var inner: f32 = @max(radius - sdf.noise_amplitude - cell_margin, 0);
    var outer: f32 = radius + sdf.noise_amplitude + cell_margin;
    for (0..24) |_| {
        const middle = (inner + outer) * 0.5;
        if (sdf.sdf(nz.vec.scale(unit_direction, middle), radius) < 0) inner = middle else outer = middle;
    }
    return nz.vec.scale(unit_direction, (inner + outer) * 0.5);
}

test surfacePoint {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    for ([_]f32{ 8, 15, 60, 100 }) |radius| {
        for (0..50) |_| {
            const direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
            const point = surfacePoint(direction, radius);
            try std.testing.expect(@abs(sdf.sdf(point, radius)) < 0.001);
            const near = surfacePointNear(direction, radius, 15, 25, random);
            try std.testing.expect(@abs(sdf.sdf(near, radius)) < 0.001);
        }
    }
}

pub fn surfacePointNear(direction: nz.Vec3(f32), radius: f32, min_distance: f32, max_distance: f32, random: std.Random) nz.Vec3(f32) {
    const unit_direction = nz.vec.normalize(direction);
    const reference: nz.Vec3(f32) = if (@abs(unit_direction[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const tangent_a = nz.vec.normalize(nz.vec.cross(unit_direction, reference));
    const tangent_b = nz.vec.cross(unit_direction, tangent_a);
    const spin = random.float(f32) * std.math.tau;
    const tangent = nz.vec.scale(tangent_a, @cos(spin)) + nz.vec.scale(tangent_b, @sin(spin));
    const distance = min_distance + random.float(f32) * (max_distance - min_distance);
    const angle = distance / radius;
    const tilted = nz.vec.scale(unit_direction, @cos(angle)) + nz.vec.scale(tangent, @sin(angle));
    return surfacePoint(tilted, radius);
}
