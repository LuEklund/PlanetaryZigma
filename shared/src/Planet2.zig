const std = @import("std");
const nz = @import("numz");

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

        pub fn init(gpa: std.mem.Allocator, size: u32) !@This() {
            if (kind == .logical) @panic("logical planet: build navmesh nodes from node_map (reuse the cells + neighbours), don't generate triangles like renderable");
            const clamped_size: f32 = if (size < 4) 4.0 else @floatFromInt(size);
            const radius: f32 = @divTrunc(clamped_size, 2);
            // var points = try gpa.alloc(u32[3], clamped_size);
            // defer gpa.free(points);
            // const center_pos: nz.Vec3(f32) = .{ 0, 0, 0 };
            var vertices: std.ArrayList(Vertex) = .empty;
            var indices: std.ArrayList(u32) = .empty;
            var node_map: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), nz.Vec3(f32)) = .empty;
            defer node_map.deinit(gpa);
            const start: f32 = -clamped_size;
            var x: f32 = start;
            while (x < clamped_size) : (x += 1) {
                var y: f32 = start;
                while (y < clamped_size) : (y += 1) {
                    var z: f32 = start;
                    while (z < clamped_size) : (z += 1) {
                        var checksum: u8 = 0;
                        var corners: [8]nz.Vec3(f32) = undefined;
                        for (0..8) |i| {
                            corners[i] = .{
                                x + cube_corners[i][0],
                                y + cube_corners[i][1],
                                z + cube_corners[i][2],
                            };
                            if (isSolid(corners[i], radius)) checksum += 1;
                        }
                        if (checksum % 8 == 0) continue;

                        var count: f32 = 0;
                        var sum: nz.Vec3(f32) = @splat(0);
                        for (cube_edges) |edge| {
                            const d1 = nz.vec.length(corners[edge[0]]) - radius;
                            const d2 = nz.vec.length(corners[edge[1]]) - radius;
                            if ((d1 < 0.0) != (d2 < 0.0)) {
                                count += 1;
                                const interp1: f32 = d1 / (d1 - d2);
                                const interp2: f32 = 1.0 - interp1;

                                sum += nz.vec.scale(corners[edge[0]], interp2) + nz.vec.scale(corners[edge[1]], interp1);
                            }
                        }
                        const centroid = nz.vec.scale(sum, 1 / count);
                        const cell: nz.Vec3(i32) = .{ @intFromFloat(x), @intFromFloat(y), @intFromFloat(z) };
                        try node_map.put(gpa, cell, centroid);
                    }
                }
            }

            const quad_axes = [3]struct { edge_axis: nz.Vec3(i32), perp_b: nz.Vec3(i32), perp_c: nz.Vec3(i32) }{
                .{ .edge_axis = .{ 1, 0, 0 }, .perp_b = .{ 0, 1, 0 }, .perp_c = .{ 0, 0, 1 } },
                .{ .edge_axis = .{ 0, 1, 0 }, .perp_b = .{ 0, 0, 1 }, .perp_c = .{ 1, 0, 0 } },
                .{ .edge_axis = .{ 0, 0, 1 }, .perp_b = .{ 1, 0, 0 }, .perp_c = .{ 0, 1, 0 } },
            };

            for (node_map.keys()) |cell| {
                const corner_a: nz.Vec3(f32) = @floatFromInt(cell);
                for (quad_axes) |quad_axis| {
                    const corner_b: nz.Vec3(f32) = corner_a + @as(nz.Vec3(f32), @floatFromInt(quad_axis.edge_axis));
                    const corner_a_solid = isSolid(corner_a, radius);
                    const corner_b_solid = isSolid(corner_b, radius);
                    if (corner_a_solid == corner_b_solid) continue;

                    const c1 = node_map.get(cell) orelse continue;
                    const c2 = node_map.get(cell - quad_axis.perp_b) orelse continue;
                    const c3 = node_map.get(cell - quad_axis.perp_c) orelse continue;
                    const c4 = node_map.get(cell - quad_axis.perp_b - quad_axis.perp_c) orelse continue;

                    const base: u32 = @intCast(vertices.items.len);
                    try vertices.append(gpa, makeVertex(c1, .{ 0, 0 }));
                    try vertices.append(gpa, makeVertex(c2, .{ 1, 0 }));
                    try vertices.append(gpa, makeVertex(c3, .{ 0, 1 }));
                    try vertices.append(gpa, makeVertex(c4, .{ 1, 1 }));

                    if (corner_a_solid) {
                        try indices.appendSlice(gpa, &.{ base + 0, base + 1, base + 3, base + 0, base + 3, base + 2 });
                    } else {
                        try indices.appendSlice(gpa, &.{ base + 0, base + 3, base + 1, base + 0, base + 2, base + 3 });
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
        fn makeVertex(position: nz.Vec3(f32), uv: [2]f32) Vertex {
            return switch (kind) {
                .logical => .{ position[0], position[1], position[2], 1 },
                .renderable => .{
                    .position = position,
                    .normal = nz.vec.normalize(position),
                    .color = .{ if (position[0] < 0) 0 else 1, if (position[1] < 0) 0 else 1, if (position[2] < 0) 0 else 1, 1 },
                    .uv_x = uv[0],
                    .uv_y = uv[1],
                },
            };
        }
        fn isSolid(position: nz.Vec3(f32), radius: f32) bool {
            return (nz.vec.distance(position, .{ 0, 0, 0 }) < radius);
        }
    };
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
    .{ 0b000, 0b001 },
    .{ 0b000, 0b010 },
    .{ 0b000, 0b100 },
    .{ 0b001, 0b011 },
    .{ 0b001, 0b101 },
    .{ 0b010, 0b011 },
    .{ 0b010, 0b110 },
    .{ 0b011, 0b111 },
    .{ 0b100, 0b101 },
    .{ 0b100, 0b110 },
    .{ 0b101, 0b111 },
    .{ 0b110, 0b111 },
};
