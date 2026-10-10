const Mesh = @This();

const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const Chunk = @import("Chunk.zig");

vertices: std.ArrayList(Vertex),
indices: std.ArrayList(u32),
opaque_index_count: u32,

pub const Vertex = @import("../vertex.zig").StaticVertex;
const Biome = @import("../Biome.zig");
const decoration = @import("decoration.zig");

pub fn generate(gpa: std.mem.Allocator, chunk: *const Chunk, planet_radius: u32) !Mesh {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const owned: Chunk.CellRegion = .{
        .min = Chunk.min(chunk.coord),
        .max = Chunk.max(chunk.coord),
    };
    const radius_float: f32 = @floatFromInt(planet_radius);
    const biome = Biome.forRadius(planet_radius);
    const water_level = if (biome.water) |water| radius_float + water.level else -std.math.inf(f32);
    var water_quads: std.ArrayList([4]nz.Vec3(f32)) = .empty;
    defer water_quads.deinit(gpa);

    var chunk_mesh: Mesh = .{ .vertices = .empty, .indices = .empty, .opaque_index_count = 0 };
    errdefer chunk_mesh.deinit(gpa);
    const normals = try gpa.alloc(nz.Vec3(f32), chunk.surface_cells.count());
    defer gpa.free(normals);
    for (chunk.surface_cells.values(), normals) |centroid, *normal| {
        normal.* = nz.vec.normalize(sdf.gradient(centroid, radius_float));
    }

    for (chunk.surface_cells.keys()) |anchor| {
        if (!owned.contains(anchor)) continue;
        for (Chunk.quad_axes) |quad_axis| {
            const edge_start_solid = chunk.density.isSolidAt(anchor);
            const edge_end_solid = chunk.density.isSolidAt(anchor + quad_axis.edge_axis);
            if (edge_start_solid == edge_end_solid) continue;

            const corner_b = anchor - quad_axis.perp_b;
            const corner_c = anchor - quad_axis.perp_c;
            const corner_bc = anchor - quad_axis.perp_b - quad_axis.perp_c;
            const index_b = chunk.surface_cells.getIndex(corner_b) orelse continue;
            const index_c = chunk.surface_cells.getIndex(corner_c) orelse continue;
            const index_bc = chunk.surface_cells.getIndex(corner_bc) orelse continue;

            const index_anchor = chunk.surface_cells.getIndex(anchor).?;
            const centroids = chunk.surface_cells.values();
            const quad = [4]nz.Vec3(f32){ centroids[index_anchor], centroids[index_b], centroids[index_c], centroids[index_bc] };
            for (quad) |corner| {
                if (nz.vec.length(corner) >= water_level) continue;
                try water_quads.append(gpa, quad);
                break;
            }
            const base_vertex_index: u32 = @intCast(chunk_mesh.vertices.items.len);
            try chunk_mesh.appendVertex(
                gpa,
                centroids[index_anchor],
                normals[index_anchor],
                .{ 0, 0 },
                radius_float,
            );
            try chunk_mesh.appendVertex(
                gpa,
                centroids[index_b],
                normals[index_b],
                .{ 1, 0 },
                radius_float,
            );
            try chunk_mesh.appendVertex(
                gpa,
                centroids[index_c],
                normals[index_c],
                .{ 0, 1 },
                radius_float,
            );
            try chunk_mesh.appendVertex(
                gpa,
                centroids[index_bc],
                normals[index_bc],
                .{ 1, 1 },
                radius_float,
            );
            try chunk_mesh.appendQuadIndices(gpa, base_vertex_index, edge_start_solid);
        }
    }

    try decoration.appendProps(gpa, &chunk_mesh, chunk, owned, normals, radius_float, biome);
    chunk_mesh.opaque_index_count = @intCast(chunk_mesh.indices.items.len);
    if (biome.water) |water| try decoration.appendWater(gpa, &chunk_mesh, water_quads.items, water_level, water.color);
    return chunk_mesh;
}

pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
    self.vertices.deinit(gpa);
    self.indices.deinit(gpa);
}

fn appendVertex(
    self: *Mesh,
    gpa: std.mem.Allocator,
    position: nz.Vec3(f32),
    normal: nz.Vec3(f32),
    uv: [2]f32,
    planet_radius: f32,
) !void {
    const biome = Biome.forRadius(@intFromFloat(planet_radius));
    const height = nz.vec.length(position);
    const height_fraction = std.math.clamp((height - planet_radius) / 30, 0, 1);
    const up = nz.vec.normalize(position);
    const steepness = std.math.clamp((1 - nz.vec.dot(normal, up) - 0.25) / 0.35, 0, 1);
    const low_color: nz.Vec3(f32) = biome.low_color;
    const high_color: nz.Vec3(f32) = biome.high_color;
    const steep_color: nz.Vec3(f32) = biome.steep_color;
    const height_color = nz.vec.scale(
        low_color,
        1 - height_fraction,
    ) + nz.vec.scale(high_color, height_fraction);
    const color = nz.vec.scale(height_color, 1 - steepness) + nz.vec.scale(steep_color, steepness);
    try self.vertices.append(gpa, .{
        .position = position,
        .normal = normal,
        .color = .{ color[0], color[1], color[2], 1 },
        .uv_x = uv[0],
        .uv_y = uv[1],
    });
}

fn appendQuadIndices(
    self: *Mesh,
    gpa: std.mem.Allocator,
    base_vertex_index: u32,
    edge_start_solid: bool,
) !void {
    if (edge_start_solid) {
        try self.indices.appendSlice(
            gpa,
            &.{
                base_vertex_index + 0,
                base_vertex_index + 1,
                base_vertex_index + 3,
                base_vertex_index + 0,
                base_vertex_index + 3,
                base_vertex_index + 2,
            },
        );
    } else {
        try self.indices.appendSlice(
            gpa,
            &.{
                base_vertex_index + 0,
                base_vertex_index + 3,
                base_vertex_index + 1,
                base_vertex_index + 0,
                base_vertex_index + 2,
                base_vertex_index + 3,
            },
        );
    }
}
