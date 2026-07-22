const std = @import("std");
const nz = @import("numz");

const noise_frequency = 0.03;
const noise_amplitude = 5;
const cell_margin = 1;

pub const min_radius: u32 = 8;
pub const radius_max: u32 = 80;
pub const dev_radius_min: u32 = 1000;
pub const dev_radius_max: u32 = 1100;
pub const chunk_dim: i32 = 32;

pub const ChunkRange = struct { min: i32, max: i32 };

pub const ChunkBox = struct { min: nz.Vec3(i32), max: nz.Vec3(i32) };

pub const ChunkClass = enum { empty, solid, surface };

pub const StageTimings = struct {
    io: std.Io,
    density_ns: u64,
    surface_nodes_ns: u64,
    mesh_ns: u64,

    pub fn init(io: std.Io) StageTimings {
        return .{ .io = io, .density_ns = 0, .surface_nodes_ns = 0, .mesh_ns = 0 };
    }

    pub fn lap(self: *StageTimings, stage_start: *std.Io.Clock.Timestamp, accumulator: *u64) void {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        accumulator.* += @intCast(stage_start.durationTo(now).raw.nanoseconds);
        stage_start.* = now;
    }

    pub fn elapsedNs(self: StageTimings, start: std.Io.Clock.Timestamp) u64 {
        return @intCast(start.durationTo(std.Io.Clock.Timestamp.now(self.io, .awake)).raw.nanoseconds);
    }

    pub fn log(self: StageTimings, chunk_count: usize, total_ns: u64) void {
        std.log.debug("planet chunks: count={d}, total={d:.2} ms, density={d:.2} ms, surface nodes={d:.2} ms, mesh={d:.2} ms", .{
            chunk_count,
            msFromNs(total_ns),
            msFromNs(self.density_ns),
            msFromNs(self.surface_nodes_ns),
            msFromNs(self.mesh_ns),
        });
    }
};

fn msFromNs(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

const classify_margin: f32 = noise_amplitude + cell_margin + 1;

pub fn chunkClassify(radius: u32, chunk: nz.Vec3(i32)) ChunkClass {
    const box_min: nz.Vec3(f32) = @floatFromInt(chunkMin(chunk));
    const box_max: nz.Vec3(f32) = @floatFromInt(chunkMax(chunk));
    const nearest = @max(box_min, @min(box_max, @as(nz.Vec3(f32), @splat(0))));
    const farthest = @max(@abs(box_min), @abs(box_max));
    const radius_float: f32 = @floatFromInt(@max(radius, min_radius));
    if (nz.vec.length(nearest) > radius_float + classify_margin) return .empty;
    if (nz.vec.length(farthest) < radius_float - classify_margin) return .solid;
    return .surface;
}

pub fn surfaceChunks(gpa: std.mem.Allocator, radius: u32, clamp: ?ChunkBox) ![]nz.Vec3(i32) {
    var chunks: std.ArrayList(nz.Vec3(i32)) = .empty;
    errdefer chunks.deinit(gpa);
    const range = chunkRange(radius);
    var min: nz.Vec3(i32) = @splat(range.min);
    var max: nz.Vec3(i32) = @splat(range.max);
    if (clamp) |box| {
        min = @max(min, box.min);
        max = @min(max, box.max);
    }
    var x = min[0];
    while (x <= max[0]) : (x += 1) {
        var y = min[1];
        while (y <= max[1]) : (y += 1) {
            var z = min[2];
            while (z <= max[2]) : (z += 1) {
                const chunk: nz.Vec3(i32) = .{ x, y, z };
                if (chunkClassify(radius, chunk) == .surface) try chunks.append(gpa, chunk);
            }
        }
    }
    return chunks.toOwnedSlice(gpa);
}

pub fn chunkCoord(position: nz.Vec3(f32)) nz.Vec3(i32) {
    return @intFromFloat(@floor(position / @as(nz.Vec3(f32), @splat(@floatFromInt(chunk_dim)))));
}

pub fn chunkMin(chunk: nz.Vec3(i32)) nz.Vec3(i32) {
    return chunk * @as(nz.Vec3(i32), @splat(chunk_dim));
}

pub fn chunkMax(chunk: nz.Vec3(i32)) nz.Vec3(i32) {
    return chunkMin(chunk) + @as(nz.Vec3(i32), @splat(chunk_dim));
}

/// Inclusive chunk-coordinate range containing the complete density field.
/// The extra cells are the same margin used by monolithic generation.
pub fn chunkRange(radius: u32) ChunkRange {
    const bound: i32 = @intCast(@max(radius, min_radius) + noise_amplitude + cell_margin);
    return .{
        .min = @divFloor(-bound, chunk_dim),
        .max = @divFloor(bound, chunk_dim),
    };
}

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
            .renderable => @import("vertex.zig").StaticVertex,
        };

        pub fn init(gpa: std.mem.Allocator, radius: u32, timer_io: ?std.Io) !@This() {
            timer_io = null;
            const generation_start = if (timer_io) |io| std.Io.Clock.Timestamp.now(io, .awake) else null;
            if (timer_io != null) std.debug.print("Planet generation start: radius={d}\n", .{radius});
            const radius_float: f32 = @floatFromInt(@max(radius, min_radius));

            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            const bound: f32 = @ceil(radius_float + noise_amplitude + cell_margin);
            var density = try DensityGrid.init(gpa, radius_float, bound);
            defer density.deinit(gpa);
            if (timer_io) |io| printStageInfo(io, "density grid", generation_start.?);

            const surface_nodes_start = if (timer_io) |io| std.Io.Clock.Timestamp.now(io, .awake) else null;
            try sdf_surface_nodes.build(gpa, &node_map, &density, radius_float, bound);
            if (timer_io) |io| printStageInfo(io, "surface nodes", surface_nodes_start.?);

            const mesh_start = if (timer_io) |io| std.Io.Clock.Timestamp.now(io, .awake) else null;

            const planet = try buildMesh(gpa, &node_map, &density, radius_float, null);
            if (timer_io) |io| {
                printStageInfo(io, "mesh", mesh_start.?);
                const total_elapsed_ns = generation_start.?.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
                const total_elapsed_ms: f64 = @as(f64, @floatFromInt(total_elapsed_ns)) / std.time.ns_per_ms;
                std.debug.print("Planet generation end: total={d:.2} ms, indices={d}, vertices={d}\n", .{
                    total_elapsed_ms, planet.indices.len, planet.vertices.len,
                });
            }

            return planet;
        }

        pub fn initChunk(gpa: std.mem.Allocator, radius: u32, chunk: nz.Vec3(i32), timings: ?*StageTimings) !@This() {
            const radius_float: f32 = @floatFromInt(@max(radius, min_radius));
            const cell_min = chunkMin(chunk);
            const cell_max = chunkMax(chunk);
            const apron_min = cell_min - @as(nz.Vec3(i32), @splat(1));

            var stage_start: std.Io.Clock.Timestamp = if (timings) |timing| .now(timing.io, .awake) else undefined;

            var density = try DensityGrid.initRegion(gpa, radius_float, apron_min, cell_max);
            defer density.deinit(gpa);
            if (timings) |timing| timing.lap(&stage_start, &timing.density_ns);

            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            try sdf_surface_nodes.buildRegion(gpa, &node_map, &density, apron_min, cell_max);
            if (timings) |timing| timing.lap(&stage_start, &timing.surface_nodes_ns);

            const planet = try buildMesh(gpa, &node_map, &density, radius_float, .{ .min = cell_min, .max = cell_max });
            if (timings) |timing| timing.lap(&stage_start, &timing.mesh_ns);
            return planet;
        }

        fn buildMesh(gpa: std.mem.Allocator, node_map: *const std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, radius: f32, owned_region: ?CellRegion) !@This() {
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

fn printStageInfo(io: std.Io, name: []const u8, start: std.Io.Clock.Timestamp) void {
    const elapsed_ns = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    std.debug.print("  {s}: {d:.2} ms\n", .{ name, elapsed_ms });
}

const DensityGrid = struct {
    // Grid-space coordinate stored at values[0, 0, 0].
    origin_offset: nz.Vec3(i32),
    resolution: usize,
    values: []f32,

    const SliceTask = struct {
        values: []f32,
        origin: nz.Vec3(i32),
        resolution: usize,
        radius: f32,
        x_start: usize,
        x_end: usize,
    };

    fn init(gpa: std.mem.Allocator, radius: f32, bound: f32) !DensityGrid {
        const min_coordinate: i32 = -@as(i32, @intFromFloat(bound));
        const origin: nz.Vec3(i32) = .{ min_coordinate, min_coordinate, min_coordinate };
        const max_coordinate: i32 = @as(i32, @intFromFloat(bound));
        return initRegion(gpa, radius, origin, .{ max_coordinate, max_coordinate, max_coordinate });
    }

    fn initRegion(gpa: std.mem.Allocator, radius: f32, cell_min: nz.Vec3(i32), cell_max: nz.Vec3(i32)) !DensityGrid {
        const origin = cell_min;
        const size = cell_max - cell_min + @as(nz.Vec3(i32), @splat(1));
        std.debug.assert(size[0] > 0 and size[1] > 0 and size[2] > 0);
        std.debug.assert(size[0] == size[1] and size[1] == size[2]);
        const resolution: usize = @intCast(size[0]);
        const plane_len = try std.math.mul(usize, resolution, resolution);
        const value_count = try std.math.mul(usize, plane_len, resolution);
        const values = try gpa.alloc(f32, value_count);
        errdefer gpa.free(values);

        const worker_count = if (resolution < 64) 1 else @max(1, @min(resolution, std.Thread.getCpuCount() catch 1));
        const tasks = try gpa.alloc(SliceTask, worker_count);
        defer gpa.free(tasks);

        const base = resolution / worker_count;
        const remainder = resolution % worker_count;
        var x_start: usize = 0;
        for (tasks, 0..) |*task, worker_index| {
            const width = base + @as(usize, @intFromBool(worker_index < remainder));
            task.* = .{
                .values = values,
                .origin = origin,
                .resolution = resolution,
                .radius = radius,
                .x_start = x_start,
                .x_end = x_start + width,
            };
            x_start += width;
        }

        try runParallelTasks(gpa, tasks, buildSlice);

        return .{ .origin_offset = origin, .resolution = resolution, .values = values };
    }

    fn deinit(self: DensityGrid, gpa: std.mem.Allocator) void {
        gpa.free(self.values);
    }

    fn densityAt(self: *const DensityGrid, grid_point: nz.Vec3(i32)) f32 {
        const local_point = grid_point - self.origin_offset;
        const x: usize = @intCast(local_point[0]);
        const y: usize = @intCast(local_point[1]);
        const z: usize = @intCast(local_point[2]);
        return self.values[(x * self.resolution + y) * self.resolution + z];
    }

    fn isSolidAt(self: *const DensityGrid, grid_point: nz.Vec3(i32)) bool {
        return self.densityAt(grid_point) < 0;
    }

    fn buildSlice(task: *const SliceTask) void {
        for (task.x_start..task.x_end) |x| {
            const x_coord: i32 = task.origin[0] + @as(i32, @intCast(x));
            for (0..task.resolution) |y| {
                const y_coord: i32 = task.origin[1] + @as(i32, @intCast(y));
                for (0..task.resolution) |z| {
                    const z_coord: i32 = task.origin[2] + @as(i32, @intCast(z));
                    const position: nz.Vec3(f32) = @floatFromInt(nz.Vec3(i32){ x_coord, y_coord, z_coord });
                    task.values[(x * task.resolution + y) * task.resolution + z] = sdf(position, task.radius);
                }
            }
        }
    }
};

// Extracts all density-zero surfaces: exterior terrain, caves, and tunnels.
const sdf_surface_nodes = struct {
    const Node = struct {
        cell: nz.Vec3(i32),
        centroid: nz.Vec3(f32),
    };

    const SliceTask = struct {
        gpa: std.mem.Allocator,
        density: *const DensityGrid,
        radius: f32,
        bound: f32,
        x_start: f32,
        x_end: f32,
        nodes: std.ArrayList(Node),
        err: ?std.mem.Allocator.Error,
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

    fn build(gpa: std.mem.Allocator, node_map: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, radius: f32, bound: f32) !void {
        const total_steps: usize = @intFromFloat(@ceil(2 * bound));
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const worker_count = @max(1, @min(total_steps, cpu_count));

        const tasks = try gpa.alloc(SliceTask, worker_count);
        defer gpa.free(tasks);

        const base = total_steps / worker_count;
        const remainder = total_steps % worker_count;
        var step_offset: usize = 0;
        for (tasks, 0..) |*task, index| {
            const steps = base + @as(usize, @intFromBool(index < remainder));
            task.* = .{
                .gpa = gpa,
                .density = density,
                .radius = radius,
                .bound = bound,
                .x_start = -bound + @as(f32, @floatFromInt(step_offset)),
                .x_end = -bound + @as(f32, @floatFromInt(step_offset + steps)),
                .nodes = .empty,
                .err = null,
            };
            step_offset += steps;
        }
        defer for (tasks) |*task| task.nodes.deinit(gpa);

        try runParallelTasks(gpa, tasks, buildSlice);

        for (tasks) |*task| {
            if (task.err) |err| return err;
            for (task.nodes.items) |node| try node_map.put(gpa, node.cell, node.centroid);
        }
    }

    fn buildRegion(gpa: std.mem.Allocator, node_map: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), density: *const DensityGrid, cell_min: nz.Vec3(i32), cell_max: nz.Vec3(i32)) !void {
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

    fn buildSlice(task: *SliceTask) void {
        var x = task.x_start;
        while (x < task.x_end) : (x += 1) {
            var y = -task.bound;
            while (y < task.bound) : (y += 1) {
                var z = -task.bound;
                while (z < task.bound) : (z += 1) {
                    scanCell(task, x, y, z);
                }
            }
        }
    }

    fn scanCell(task: *SliceTask, x: f32, y: f32, z: f32) void {
        const cell_position: nz.Vec3(f32) = .{ x, y, z };
        const cell_center = cell_position + @as(nz.Vec3(f32), @splat(0.5));
        if (nz.vec.length(cell_center) > task.bound) return;
        const cell: nz.Vec3(i32) = @intFromFloat(cell_position);
        var checksum: u8 = 0;
        var corners: [8]nz.Vec3(f32) = undefined;
        var corner_sdf: [8]f32 = undefined;
        for (0..8) |i| {
            const corner_cell = cell + cube_corner_offsets[i];
            corners[i] = @floatFromInt(corner_cell);
            corner_sdf[i] = task.density.densityAt(corner_cell);
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
                const start_weight: f32 = 1.0 - crossing_fraction;
                const end_weight: f32 = crossing_fraction;
                const start_corner = corners[edge[0]];
                const end_corner = corners[edge[1]];
                crossing_sum += nz.vec.scale(start_corner, start_weight) + nz.vec.scale(end_corner, end_weight);
            }
        }
        const centroid = nz.vec.scale(crossing_sum, 1 / crossing_count);
        task.nodes.append(task.gpa, .{ .cell = cell, .centroid = centroid }) catch |err| {
            task.err = err;
            return;
        };
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

fn runParallelTasks(gpa: std.mem.Allocator, tasks: anytype, comptime worker: anytype) !void {
    std.debug.assert(tasks.len > 0);
    if (tasks.len == 1) {
        worker(&tasks[0]);
        return;
    }

    const threads = try gpa.alloc(std.Thread, tasks.len);
    defer gpa.free(threads);
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    while (spawned < tasks.len) : (spawned += 1)
        threads[spawned] = try std.Thread.spawn(.{}, worker, .{&tasks[spawned]});
    for (threads) |thread| thread.join();
}

pub fn sdf(position: nz.Vec3(f32), radius: f32) f32 {
    const sample = nz.vec.scale(position, noise_frequency);
    const noise = simplex3(sample[0], sample[1], sample[2]) * noise_amplitude;
    return nz.vec.length(position) - radius + noise;
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

test "chunk coordinates cover chunk_dim cells" {
    const chunk: nz.Vec3(i32) = .{ -2, 3, 0 };
    try std.testing.expectEqual(nz.Vec3(i32){ -64, 96, 0 }, chunkMin(chunk));
    try std.testing.expectEqual(nz.Vec3(i32){ -32, 128, 32 }, chunkMax(chunk));
}

test "chunk range contains the complete planet density field" {
    try std.testing.expectEqual(ChunkRange{ .min = -1, .max = 0 }, chunkRange(18));
    try std.testing.expectEqual(ChunkRange{ .min = -3, .max = 2 }, chunkRange(67));
}

test "a surface chunk builds logical nodes" {
    const chunk: nz.Vec3(i32) = .{ 0, 0, 0 };
    const planet = try Planet(.logical).initChunk(std.testing.allocator, 18, chunk, null);
    defer planet.deinit(std.testing.allocator);
    try std.testing.expect(planet.vertices.len > 0);
}

test "tiled chunks emit the monolith's surface index count" {
    const radius = 18;
    const monolith = try Planet(.renderable).init(std.testing.allocator, radius, null);
    defer monolith.deinit(std.testing.allocator);

    var chunk_index_count: usize = 0;
    const range = chunkRange(radius);
    var x = range.min;
    while (x <= range.max) : (x += 1) {
        var y = range.min;
        while (y <= range.max) : (y += 1) {
            var z = range.min;
            while (z <= range.max) : (z += 1) {
                const chunk = try Planet(.renderable).initChunk(std.testing.allocator, radius, .{ x, y, z }, null);
                defer chunk.deinit(std.testing.allocator);
                chunk_index_count += chunk.indices.len;
            }
        }
    }
    try std.testing.expectEqual(monolith.indices.len, chunk_index_count);
}

test "every chunk with geometry is classified surface" {
    for ([_]u32{ 18, 40 }) |radius| {
        const range = chunkRange(radius);
        var x = range.min;
        while (x <= range.max) : (x += 1) {
            var y = range.min;
            while (y <= range.max) : (y += 1) {
                var z = range.min;
                while (z <= range.max) : (z += 1) {
                    const chunk: nz.Vec3(i32) = .{ x, y, z };
                    const planet = try Planet(.logical).initChunk(std.testing.allocator, radius, chunk, null);
                    defer planet.deinit(std.testing.allocator);
                    if (planet.indices.len > 0)
                        try std.testing.expectEqual(ChunkClass.surface, chunkClassify(radius, chunk));
                }
            }
        }
    }
}

test "surface chunks respect the clamp box" {
    const box: ChunkBox = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    const chunks = try surfaceChunks(std.testing.allocator, 67, box);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len > 0);
    for (chunks) |chunk| {
        try std.testing.expect(@reduce(.And, chunk >= box.min));
        try std.testing.expect(@reduce(.And, chunk <= box.max));
    }
}

pub fn surfacePoint(direction: nz.Vec3(f32), radius: f32) nz.Vec3(f32) {
    const unit_direction = nz.vec.normalize(direction);
    var inner: f32 = @max(radius - noise_amplitude - cell_margin, 0);
    var outer: f32 = radius + noise_amplitude + cell_margin;
    for (0..24) |_| {
        const middle = (inner + outer) * 0.5;
        if (sdf(nz.vec.scale(unit_direction, middle), radius) < 0) inner = middle else outer = middle;
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
            try std.testing.expect(@abs(sdf(point, radius)) < 0.001);
            const near = surfacePointNear(direction, radius, 15, 25, random);
            try std.testing.expect(@abs(sdf(near, radius)) < 0.001);
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

pub fn ChunkJob(comptime kind: PlanetKind) type {
    return struct {
        thread: std.Thread,
        state: *State,

        pub const Result = struct {
            coord: nz.Vec3(i32),
            vertices: []Planet(kind).Vertex,
            indices: []u32,
        };

        pub const State = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            radius: u32,
            coords: []nz.Vec3(i32),
            results: std.ArrayList(Result),
            done: std.atomic.Value(bool),
        };

        pub fn start(gpa: std.mem.Allocator, io: std.Io, radius: u32, coords: []nz.Vec3(i32)) !@This() {
            errdefer gpa.free(coords);
            const state = try gpa.create(State);
            errdefer gpa.destroy(state);
            state.* = .{ .gpa = gpa, .io = io, .radius = radius, .coords = coords, .results = .empty, .done = .init(false) };
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
            for (self.state.results.items) |result| {
                self.state.gpa.free(result.vertices);
                self.state.gpa.free(result.indices);
            }
            self.state.results.deinit(self.state.gpa);
            self.state.gpa.free(self.state.coords);
            self.state.gpa.destroy(self.state);
        }

        fn generate(state: *State) void {
            var timings: StageTimings = .init(state.io);
            const build_start = std.Io.Clock.Timestamp.now(state.io, .awake);
            for (state.coords) |coord| {
                const planet = Planet(kind).initChunk(state.gpa, state.radius, coord, &timings) catch continue;
                state.results.append(state.gpa, .{ .coord = coord, .vertices = planet.vertices, .indices = planet.indices }) catch planet.deinit(state.gpa);
            }
            timings.log(state.results.items.len, timings.elapsedNs(build_start));
            state.done.store(true, .release);
        }
    };
}

const grad3 = [12][3]f32{
    .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 },
    .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 },
    .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 },
};

const perm = blk: {
    const p = [_]u8{
        151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
        140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
        247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
        57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
        74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
        60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
        65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
        200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
        52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
        207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
        119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
        129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
        218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
        81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
        184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
        222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    };
    var p2: [512]u8 = undefined;
    for (0..256) |i| {
        p2[i] = p[i];
        p2[i + 256] = p[i];
    }
    break :blk p2;
};

fn dot3(g: [3]f32, x: f32, y: f32, z: f32) f32 {
    return g[0] * x + g[1] * y + g[2] * z;
}

pub fn simplex3(xin: f32, yin: f32, zin: f32) f32 {
    const F3 = 1.0 / 3.0;
    const G3 = 1.0 / 6.0;

    const s = (xin + yin + zin) * F3;
    const i: i32 = @intFromFloat(@floor(xin + s));
    const j: i32 = @intFromFloat(@floor(yin + s));
    const k: i32 = @intFromFloat(@floor(zin + s));

    const t = @as(f32, @floatFromInt(i + j + k)) * G3;
    const x0 = xin - (@as(f32, @floatFromInt(i)) - t);
    const y0 = yin - (@as(f32, @floatFromInt(j)) - t);
    const z0 = zin - (@as(f32, @floatFromInt(k)) - t);

    var i_1: i32 = 0;
    var j_1: i32 = 0;
    var k_1: i32 = 0;
    var i_2: i32 = 0;
    var j_2: i32 = 0;
    var k_2: i32 = 0;
    if (x0 >= y0) {
        if (y0 >= z0) {
            i_1 = 1;
            j_1 = 0;
            k_1 = 0;
            i_2 = 1;
            j_2 = 1;
            k_2 = 0;
        } else if (x0 >= z0) {
            i_1 = 1;
            j_1 = 0;
            k_1 = 0;
            i_2 = 1;
            j_2 = 0;
            k_2 = 1;
        } else {
            i_1 = 0;
            j_1 = 0;
            k_1 = 1;
            i_2 = 1;
            j_2 = 0;
            k_2 = 1;
        }
    } else {
        if (y0 < z0) {
            i_1 = 0;
            j_1 = 0;
            k_1 = 1;
            i_2 = 0;
            j_2 = 1;
            k_2 = 1;
        } else if (x0 < z0) {
            i_1 = 0;
            j_1 = 1;
            k_1 = 0;
            i_2 = 0;
            j_2 = 1;
            k_2 = 1;
        } else {
            i_1 = 0;
            j_1 = 1;
            k_1 = 0;
            i_2 = 1;
            j_2 = 1;
            k_2 = 0;
        }
    }

    const x1 = x0 - @as(f32, @floatFromInt(i_1)) + G3;
    const y1 = y0 - @as(f32, @floatFromInt(j_1)) + G3;
    const z1 = z0 - @as(f32, @floatFromInt(k_1)) + G3;
    const x2 = x0 - @as(f32, @floatFromInt(i_2)) + 2.0 * G3;
    const y2 = y0 - @as(f32, @floatFromInt(j_2)) + 2.0 * G3;
    const z2 = z0 - @as(f32, @floatFromInt(k_2)) + 2.0 * G3;
    const x3 = x0 - 1.0 + 3.0 * G3;
    const y3 = y0 - 1.0 + 3.0 * G3;
    const z3 = z0 - 1.0 + 3.0 * G3;

    const ii: usize = @intCast(@mod(i, 256));
    const jj: usize = @intCast(@mod(j, 256));
    const kk: usize = @intCast(@mod(k, 256));

    const gi0 = perm[ii + perm[jj + perm[kk]]] % 12;
    const gi1 = perm[ii + @as(usize, @intCast(i_1)) + perm[jj + @as(usize, @intCast(j_1)) + perm[kk + @as(usize, @intCast(k_1))]]] % 12;
    const gi2 = perm[ii + @as(usize, @intCast(i_2)) + perm[jj + @as(usize, @intCast(j_2)) + perm[kk + @as(usize, @intCast(k_2))]]] % 12;
    const gi3 = perm[ii + 1 + perm[jj + 1 + perm[kk + 1]]] % 12;

    var n0: f32 = 0;
    var n1: f32 = 0;
    var n2: f32 = 0;
    var n3: f32 = 0;
    var t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 > 0) {
        t0 *= t0;
        n0 = t0 * t0 * dot3(grad3[gi0], x0, y0, z0);
    }
    var t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 > 0) {
        t1 *= t1;
        n1 = t1 * t1 * dot3(grad3[gi1], x1, y1, z1);
    }
    var t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 > 0) {
        t2 *= t2;
        n2 = t2 * t2 * dot3(grad3[gi2], x2, y2, z2);
    }
    var t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 > 0) {
        t3 *= t3;
        n3 = t3 * t3 * dot3(grad3[gi3], x3, y3, z3);
    }

    return 32.0 * (n0 + n1 + n2 + n3); // returns -1 to 1
}
