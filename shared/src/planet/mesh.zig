const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");

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

// Extracts all density-zero surfaces: exterior terrain, caves, and tunnels.
pub const surface_nodes = struct {
    const Node = struct {
        cell: nz.Vec3(i32),
        centroid: nz.Vec3(f32),
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

    pub fn buildRegion(gpa: std.mem.Allocator, node_map: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, cell_min: nz.Vec3(i32), cell_max: nz.Vec3(i32)) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        var x = cell_min[0];
        while (x < cell_max[0]) : (x += 1) {
            var y = cell_min[1];
            while (y < cell_max[1]) : (y += 1) {
                var z = cell_min[2];
                while (z < cell_max[2]) : (z += 1) {
                    try scanRegionCell(gpa, node_map, density, .{ x, y, z });
                }
            }
        }
    }

    fn scanRegionCell(gpa: std.mem.Allocator, node_map: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, cell: nz.Vec3(i32)) !void {
        var checksum: u8 = 0;
        var corners: [8]nz.Vec3(f32) = undefined;
        var corner_sdf: [8]f32 = undefined;
        for (0..8) |i| {
            const corner_cell = cell + cube_corner_offsets[i];
            corners[i] = @floatFromInt(corner_cell);
            corner_sdf[i] = density.densityAt(corner_cell);
            if (corner_sdf[i] < 0) checksum += 1;
        }
        if (checksum == 0 or checksum == 8) return;

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
        const centroid = nz.vec.scale(crossing_sum, 1 / crossing_count);
        try node_map.put(gpa, cell, centroid);
    }
};
