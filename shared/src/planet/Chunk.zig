const Chunk = @This();

const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const planet = @import("root.zig");

pub const Mesh = @import("Mesh.zig");
pub const NavGraph = @import("NavGraph.zig");

pub const dim: i32 = 32;

surface_cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)),
density: DensityGrid,
coord: Coord,

pub fn init(gpa: std.mem.Allocator, planet_radius: u32, chunk_coord: Coord) !Chunk {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const radius_float: f32 = @floatFromInt(planet_radius);
    const cell_min = min(chunk_coord);
    const cell_max = max(chunk_coord);
    const apron_min = cell_min - @as(nz.Vec3(i32), @splat(1));
    const apron_max = cell_max + @as(nz.Vec3(i32), @splat(1));

    var density = try DensityGrid.initRegion(gpa, radius_float, apron_min, apron_max);
    errdefer density.deinit(gpa);

    var surface_cells: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
    errdefer surface_cells.deinit(gpa);
    try buildSurfaceCells(gpa, &surface_cells, &density, apron_min, apron_max);

    return .{ .surface_cells = surface_cells, .density = density, .coord = chunk_coord };
}

pub fn deinit(self: *Chunk, gpa: std.mem.Allocator) void {
    self.surface_cells.deinit(gpa);
    self.density.deinit(gpa);
}

pub const CellRegion = struct {
    min: nz.Vec3(i32),
    max: nz.Vec3(i32),

    pub fn contains(self: CellRegion, cell: nz.Vec3(i32)) bool {
        return @reduce(.And, cell >= self.min) and @reduce(.And, cell < self.max);
    }
};

pub const quad_axes = [3]struct { edge_axis: nz.Vec3(i32), perp_b: nz.Vec3(i32), perp_c: nz.Vec3(i32) }{
    .{ .edge_axis = .{ 1, 0, 0 }, .perp_b = .{ 0, 1, 0 }, .perp_c = .{ 0, 0, 1 } },
    .{ .edge_axis = .{ 0, 1, 0 }, .perp_b = .{ 0, 0, 1 }, .perp_c = .{ 1, 0, 0 } },
    .{ .edge_axis = .{ 0, 0, 1 }, .perp_b = .{ 1, 0, 0 }, .perp_c = .{ 0, 1, 0 } },
};

pub const DensityGrid = struct {
    // Grid-space coordinate stored at values[0, 0, 0].
    origin_offset: nz.Vec3(i32),
    resolution: usize,
    values: []f32,

    pub fn initRegion(gpa: std.mem.Allocator, planet_radius: f32, cell_min: nz.Vec3(i32), cell_max: nz.Vec3(i32)) !DensityGrid {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const origin = cell_min;
        const size = cell_max - cell_min + @as(nz.Vec3(i32), @splat(1));
        std.debug.assert(size[0] == size[1] and size[1] == size[2]);
        const resolution: usize = @intCast(size[0]);
        const plane_len = try std.math.mul(usize, resolution, resolution);
        const value_count = try std.math.mul(usize, plane_len, resolution);
        const values = try gpa.alloc(f32, value_count);

        for (0..resolution) |x| {
            const x_coord: i32 = origin[0] + @as(i32, @intCast(x));
            for (0..resolution) |y| {
                const y_coord: i32 = origin[1] + @as(i32, @intCast(y));
                for (0..resolution) |z| {
                    const z_coord: i32 = origin[2] + @as(i32, @intCast(z));
                    const position: nz.Vec3(f32) = @floatFromInt(nz.Vec3(i32){ x_coord, y_coord, z_coord });
                    values[(x * resolution + y) * resolution + z] = sdf.sdf(position, planet_radius);
                }
            }
        }

        return .{ .origin_offset = origin, .resolution = resolution, .values = values };
    }

    pub fn deinit(self: DensityGrid, gpa: std.mem.Allocator) void {
        gpa.free(self.values);
    }

    fn densityAt(self: *const DensityGrid, grid_point: nz.Vec3(i32)) f32 {
        const local_point = grid_point - self.origin_offset;
        const x: usize = @intCast(local_point[0]);
        const y: usize = @intCast(local_point[1]);
        const z: usize = @intCast(local_point[2]);
        return self.values[(x * self.resolution + y) * self.resolution + z];
    }

    pub fn isSolidAt(self: *const DensityGrid, grid_point: nz.Vec3(i32)) bool {
        return self.densityAt(grid_point) < 0;
    }
};

const cube_corner_offsets = [_]nz.Vec3(i32){
    .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 },
    .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 },
};

const cube_edges = [_][2]u3{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 }, .{ 1, 3 },
    .{ 1, 5 }, .{ 2, 3 }, .{ 2, 6 }, .{ 3, 7 },
    .{ 4, 5 }, .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
};

// Extracts all density-zero surfaces: exterior terrain, caves, and tunnels.
fn buildSurfaceCells(gpa: std.mem.Allocator, surface_cells: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, cell_min: nz.Vec3(i32), cell_max: nz.Vec3(i32)) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    var x = cell_min[0];
    while (x < cell_max[0]) : (x += 1) {
        var y = cell_min[1];
        while (y < cell_max[1]) : (y += 1) {
            var z = cell_min[2];
            while (z < cell_max[2]) : (z += 1) {
                const cell: nz.Vec3(i32) = .{ x, y, z };
                const centroid = cellCentroid(density, cell) orelse continue;
                try surface_cells.put(gpa, cell, centroid);
            }
        }
    }
}

fn cellCentroid(density: *const DensityGrid, cell: nz.Vec3(i32)) ?nz.Vec3(f32) {
    var checksum: u8 = 0;
    var corners: [8]nz.Vec3(f32) = undefined;
    var corner_sdf: [8]f32 = undefined;
    for (0..8) |i| {
        const corner_cell = cell + cube_corner_offsets[i];
        corners[i] = @floatFromInt(corner_cell);
        corner_sdf[i] = density.densityAt(corner_cell);
        if (corner_sdf[i] < 0) checksum += 1;
    }
    if (checksum == 0 or checksum == 8) return null;

    var crossing_count: f32 = 0;
    var crossing_sum: nz.Vec3(f32) = @splat(0);
    for (cube_edges) |edge| {
        const start_distance = corner_sdf[edge[0]];
        const end_distance = corner_sdf[edge[1]];
        if ((start_distance < 0.0) != (end_distance < 0.0)) {
            crossing_count += 1;
            const crossing_fraction: f32 = start_distance / (start_distance - end_distance);
            const start_corner = corners[edge[0]];
            const end_corner = corners[edge[1]];
            crossing_sum += nz.vec.scale(start_corner, 1.0 - crossing_fraction) + nz.vec.scale(end_corner, crossing_fraction);
        }
    }
    return nz.vec.scale(crossing_sum, 1 / crossing_count);
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
                const chunk_coord: Coord = .{ .position = .{ x, y, z } };
                const box_min: nz.Vec3(f32) = @floatFromInt(min(chunk_coord));
                const box_max: nz.Vec3(f32) = @floatFromInt(max(chunk_coord));
                const chunk_nearest_point_to_planet = @max(box_min, @min(box_max, @as(nz.Vec3(f32), @splat(0))));
                if (nz.vec.dot(chunk_nearest_point_to_planet, chunk_nearest_point_to_planet) > surface_reach_squared) continue;
                // TODO: (CAVES): DELETE THIS SKIP when caves carve the sdf!
                // It assumes fully-buried chunks are solid rock with no surface.
                // The day sdf() subtracts caves, buried chunks can contain geometry
                // and this check will silently produce holes in the world.
                const chunk_farthest_point_to_planet = @max(@abs(box_min), @abs(box_max));
                if (nz.vec.dot(chunk_farthest_point_to_planet, chunk_farthest_point_to_planet) < solid_depth_squared) continue;
                try chunks.append(gpa, chunk_coord);
            }
        }
    }
    return chunks.toOwnedSlice(gpa);
}

pub fn min(chunk_coord: Coord) nz.Vec3(i32) {
    return chunk_coord.position * @as(nz.Vec3(i32), @splat(dim));
}

pub fn max(chunk_coord: Coord) nz.Vec3(i32) {
    return min(chunk_coord) + @as(nz.Vec3(i32), @splat(dim));
}

pub fn range(planet_radius: u32) Range {
    const bound: i32 = @intCast(planet_radius + sdf.noise_amplitude + planet.cell_margin);
    return .{
        .min = @divFloor(-bound, dim),
        .max = @divFloor(bound, dim),
    };
}

test "chunk coordinates cover dim cells" {
    const chunk_coord: Coord = .{ .position = .{ -2, 3, 0 } };
    try std.testing.expectEqual(nz.Vec3(i32){ -64, 96, 0 }, min(chunk_coord));
    try std.testing.expectEqual(nz.Vec3(i32){ -32, 128, 32 }, max(chunk_coord));
}

test "chunk range contains the complete planet density field" {
    try std.testing.expectEqual(Range{ .min = -1, .max = 0 }, range(18));
    try std.testing.expectEqual(Range{ .min = -3, .max = 2 }, range(67));
}

test "chunk coords respect the clamp box" {
    const box: Box = .{ .min = .{ .position = .{ 0, 0, 0 } }, .max = .{ .position = .{ 1, 1, 1 } } };
    const clamped_coords = try coords(std.testing.allocator, 67, box);
    defer std.testing.allocator.free(clamped_coords);
    try std.testing.expect(clamped_coords.len > 0);
    for (clamped_coords) |chunk_coord| {
        try std.testing.expect(@reduce(.And, chunk_coord.position >= box.min.position));
        try std.testing.expect(@reduce(.And, chunk_coord.position <= box.max.position));
    }
}

pub const Job = struct {
    thread: std.Thread,
    state: *State,

    pub const Result = struct {
        chunk: Chunk,
        mesh: Mesh,
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
            result.chunk.deinit(self.state.gpa);
            result.mesh.deinit(self.state.gpa);
            result.nav.deinit(self.state.gpa);
        }
        self.state.results.deinit(self.state.gpa);
        self.state.gpa.free(self.state.coords);
        self.state.gpa.destroy(self.state);
    }

    fn run(state: *State) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        for (state.coords) |job_coord| {
            var chunk = init(state.gpa, state.planet_radius, job_coord) catch continue;
            var chunk_mesh = Mesh.generate(state.gpa, &chunk, state.planet_radius) catch {
                chunk.deinit(state.gpa);
                continue;
            };
            var nav = NavGraph.generate(state.gpa, &chunk) catch {
                chunk.deinit(state.gpa);
                chunk_mesh.deinit(state.gpa);
                continue;
            };
            state.results.append(state.gpa, .{ .chunk = chunk, .mesh = chunk_mesh, .nav = nav }) catch {
                chunk.deinit(state.gpa);
                chunk_mesh.deinit(state.gpa);
                nav.deinit(state.gpa);
            };
        }
        state.done.store(true, .release);
    }
};
