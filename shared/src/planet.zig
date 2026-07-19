const std = @import("std");
const nz = @import("numz");

const noise_frequency = 0.04;
const noise_amplitude = 2;
const cell_margin = 1;

pub const min_radius: u32 = 8;
pub const radius_max: u32 = 80;
pub const dev_radius_min: u32 = 20;
pub const dev_radius_max: u32 = 30;

pub const PlanetKind = enum {
    logical,
    renderable,
};

pub fn Planet(kind: PlanetKind) type {
    return struct {
        vertices: []Vertex,
        indices: []u32,

        pub const Vertex = switch (kind) {
            .logical => [4]f32,
            .renderable => @import("vertex.zig").StaticVertex,
        };

        pub fn init(gpa: std.mem.Allocator, radius: u32) !@This() {
            const radius_float: f32 = @floatFromInt(@max(radius, min_radius));

            var vertices: std.ArrayList(Vertex) = .empty;
            var indices: std.ArrayList(u32) = .empty;
            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            const bound: f32 = @ceil(radius_float + noise_amplitude + cell_margin);
            try buildNodeMap(gpa, &node_map, radius_float, bound);

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
                const edge_start: nz.Vec3(f32) = @floatFromInt(cell);
                for (quad_axes) |quad_axis| {
                    const edge_end: nz.Vec3(f32) = edge_start + @as(nz.Vec3(f32), @floatFromInt(quad_axis.edge_axis));
                    const edge_start_solid = sdf(edge_start, radius_float) < 0;
                    const edge_end_solid = sdf(edge_end, radius_float) < 0;
                    if (edge_start_solid == edge_end_solid) continue;

                    const index_at_cell: u32 = @intCast(node_map.getIndex(cell) orelse continue);
                    const index_minus_b: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_b) orelse continue);
                    const index_minus_c: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_c) orelse continue);
                    const index_minus_bc: u32 = @intCast(node_map.getIndex(cell - quad_axis.perp_b - quad_axis.perp_c) orelse continue);

                    switch (kind) {
                        .renderable => {
                            const centroids = node_map.values();
                            const base_vertex_index: u32 = @intCast(vertices.items.len);
                            try vertices.append(gpa, makeVertex(centroids[index_at_cell], .{ 0, 0 }, radius_float));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_b], .{ 1, 0 }, radius_float));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_c], .{ 0, 1 }, radius_float));
                            try vertices.append(gpa, makeVertex(centroids[index_minus_bc], .{ 1, 1 }, radius_float));

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

            return .{
                .vertices = try vertices.toOwnedSlice(gpa),
                .indices = try indices.toOwnedSlice(gpa),
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

const CellNode = struct {
    cell: nz.Vec3(i32),
    centroid: nz.Vec3(f32),
};

const SliceTask = struct {
    gpa: std.mem.Allocator,
    radius: f32,
    bound: f32,
    x_start: f32,
    x_end: f32,
    nodes: std.ArrayList(CellNode),
    err: ?std.mem.Allocator.Error,
};

fn buildNodeMap(gpa: std.mem.Allocator, node_map: *std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)), radius: f32, bound: f32) !void {
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

    if (worker_count == 1) {
        buildCellSlice(&tasks[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, worker_count);
        defer gpa.free(threads);
        var spawned: usize = 0;
        errdefer for (threads[0..spawned]) |thread| thread.join();
        while (spawned < worker_count) : (spawned += 1)
            threads[spawned] = try std.Thread.spawn(.{}, buildCellSlice, .{&tasks[spawned]});
        for (threads) |thread| thread.join();
    }

    for (tasks) |*task| {
        if (task.err) |err| return err;
        for (task.nodes.items) |node| try node_map.put(gpa, node.cell, node.centroid);
    }
}

fn buildCellSlice(task: *SliceTask) void {
    var x = task.x_start;
    while (x < task.x_end) : (x += 1) {
        var y = -task.bound;
        while (y < task.bound) : (y += 1) {
            var z = -task.bound;
            while (z < task.bound) : (z += 1) {
                const cell_position: nz.Vec3(f32) = .{ x, y, z };
                const cell_center: nz.Vec3(f32) = cell_position + @as(nz.Vec3(f32), @splat(0.5));
                const shell_half_width = noise_amplitude + cell_margin;
                if (@abs(nz.vec.length(cell_center) - task.radius) > shell_half_width) continue;
                var checksum: u8 = 0;
                var corners: [8]nz.Vec3(f32) = undefined;
                var corner_sdf: [8]f32 = undefined;
                for (0..8) |i| {
                    corners[i] = cube_corners[i] + cell_position;
                    corner_sdf[i] = sdf(corners[i], task.radius);
                    if (corner_sdf[i] < 0) checksum += 1;
                }
                if (checksum == 0 or checksum == 8) continue;

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
                const cell: nz.Vec3(i32) = .{ @intFromFloat(x), @intFromFloat(y), @intFromFloat(z) };
                task.nodes.append(task.gpa, .{ .cell = cell, .centroid = centroid }) catch |err| {
                    task.err = err;
                    return;
                };
            }
        }
    }
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

const cube_corners = [_]nz.Vec3(f32){
    .{ 0, 0, 0 },
    .{ 1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 1, 1, 0 },
    .{ 0, 0, 1 },
    .{ 1, 0, 1 },
    .{ 0, 1, 1 },
    .{ 1, 1, 1 },
};

const cube_edges = [_][2]u3{
    .{ 0, 1 },
    .{ 0, 2 },
    .{ 0, 4 },
    .{ 1, 3 },
    .{ 1, 5 },
    .{ 2, 3 },
    .{ 2, 6 },
    .{ 3, 7 },
    .{ 4, 5 },
    .{ 4, 6 },
    .{ 5, 7 },
    .{ 6, 7 },
};

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
