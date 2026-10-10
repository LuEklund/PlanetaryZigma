const std = @import("std");
const nz = @import("numz");
const Mesh = @import("Mesh.zig");
const Chunk = @import("Chunk.zig");
const PlanetType = @import("../PlanetType.zig");
const sdf = @import("sdf.zig");

const Vec3 = nz.Vec3(f32);
const Color = [3]f32;

const min_flatness: f32 = 0.8;
const sides: usize = 6;
const landing_clear_radius: f32 = 10;

const Frame = struct {
    base: Vec3,
    up: Vec3,
    right: Vec3,
    forward: Vec3,

    fn at(frame: Frame, x: f32, y: f32, z: f32) Vec3 {
        return frame.base + nz.vec.scale(frame.right, x) + nz.vec.scale(frame.up, y) + nz.vec.scale(
            frame.forward,
            z,
        );
    }
};

/// Trees, rocks and grass on the chunk's owned flat surface cells, deterministic per cell.
pub fn appendProps(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    chunk: *const Chunk,
    owned: Chunk.CellRegion,
    normals: []const Vec3,
    planet_radius: f32,
    planet_type: *const PlanetType,
) !void {
    const props = planet_type.props;
    const water_level = if (planet_type.water) |water| planet_radius + water.level else -std.math.inf(
        f32,
    );
    const cells = chunk.surface_cells;
    for (cells.keys(), cells.values(), normals) |anchor, centroid, normal| {
        if (!owned.contains(anchor)) continue;
        const up = nz.vec.normalize(centroid);
        if (nz.vec.dot(normal, up) < min_flatness) continue;
        if (nz.vec.length(centroid) < water_level) continue;
        if (@abs(sdf.terrain(centroid, planet_radius)) > Mesh.outer_surface_band) continue;
        if (centroid[1] > 0 and @sqrt(
            centroid[0] * centroid[0] + centroid[2] * centroid[2],
        ) < landing_clear_radius) continue;
        var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, std.mem.asBytes(&anchor)));
        const random = prng.random();
        const frame = frameAt(centroid, up, random.float(f32) * std.math.tau);
        const shade = 0.85 + random.float(f32) * 0.3;
        var roll = random.float(f32);
        if (roll < props.trees) {
            try appendTree(gpa, mesh, frame, random, shade, props);
            continue;
        }
        roll -= props.trees;
        if (roll < props.rocks) {
            try appendRock(gpa, mesh, frame, random, scaled(props.rock_color, shade));
            continue;
        }
        roll -= props.rocks;
        if (roll < props.grass) try appendGrass(
            gpa,
            mesh,
            frame,
            random,
            scaled(props.grass_color, shade),
        );
    }
}

/// Every terrain quad touching the water shell, flattened onto it. Call after the opaque geometry.
pub fn appendWater(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    quads: []const [4]Vec3,
    level: f32,
    color: [4]f32,
) !void {
    for (quads) |quad| {
        var shell: [4]Vec3 = undefined;
        for (quad, &shell) |corner, *projected| projected.* = nz.vec.scale(
            nz.vec.normalize(corner),
            level,
        );
        try waterTriangle(gpa, mesh, shell[0], shell[1], shell[3], color);
        try waterTriangle(gpa, mesh, shell[0], shell[3], shell[2], color);
    }
}

fn waterTriangle(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    color: [4]f32,
) !void {
    const face = nz.vec.cross(b - a, c - a);
    if (nz.vec.length(face) < 1e-6) return;
    const outward = nz.vec.dot(face, a) > 0;
    const base: u32 = @intCast(mesh.vertices.items.len);
    for ([_]Vec3{ a, b, c }) |corner| try mesh.vertices.append(gpa, .{
        .position = corner,
        .normal = nz.vec.normalize(corner),
        .color = color,
    });
    if (outward) {
        try mesh.indices.appendSlice(gpa, &.{ base, base + 1, base + 2 });
    } else {
        try mesh.indices.appendSlice(gpa, &.{ base, base + 2, base + 1 });
    }
}

fn frameAt(base: Vec3, up: Vec3, yaw: f32) Frame {
    const helper: Vec3 = if (@abs(up[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const tangent = nz.vec.normalize(nz.vec.cross(up, helper));
    const bitangent = nz.vec.cross(up, tangent);
    const right = nz.vec.scale(tangent, @cos(yaw)) + nz.vec.scale(bitangent, @sin(yaw));
    return .{ .base = base, .up = up, .right = right, .forward = nz.vec.cross(right, up) };
}

fn appendTree(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    frame: Frame,
    random: std.Random,
    shade: f32,
    props: PlanetType.Props,
) !void {
    const height = 3 + random.float(f32) * 3;
    const trunk_height = height * 0.4;
    try appendPrism(gpa, mesh, frame, -0.3, trunk_height, 0.18, scaled(props.trunk_color, shade));
    const leaves = scaled(props.leaf_color, shade);
    try appendCone(gpa, mesh, frame, trunk_height * 0.8, height * 0.45, height * 0.3, leaves);
    try appendCone(
        gpa,
        mesh,
        frame,
        trunk_height + height * 0.25,
        height * 0.4,
        height * 0.22,
        leaves,
    );
}

fn appendRock(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    frame: Frame,
    random: std.Random,
    color: Color,
) !void {
    const size = 0.3 + random.float(f32) * random.float(f32) * 1.4;
    var ring: [sides]Vec3 = undefined;
    for (&ring, 0..) |*point, index| {
        const angle = std.math.tau * @as(f32, @floatFromInt(index)) / sides;
        const reach = size * (0.7 + random.float(f32) * 0.5);
        point.* = frame.at(@cos(angle) * reach, size * 0.15, @sin(angle) * reach);
    }
    const top = frame.at(0, size * (0.6 + random.float(f32) * 0.4), 0);
    const bottom = frame.at(0, -size * 0.4, 0);
    for (0..sides) |index| {
        const next = (index + 1) % sides;
        try appendTriangle(gpa, mesh, top, ring[next], ring[index], color);
        try appendTriangle(gpa, mesh, bottom, ring[index], ring[next], color);
    }
}

fn appendGrass(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    frame: Frame,
    random: std.Random,
    color: Color,
) !void {
    for (0..3) |_| {
        const angle = random.float(f32) * std.math.tau;
        const height = 0.3 + random.float(f32) * 0.5;
        const half_width: f32 = 0.06;
        const offset_x = (random.float(f32) - 0.5) * 0.5;
        const offset_z = (random.float(f32) - 0.5) * 0.5;
        const side_x = @cos(angle) * half_width;
        const side_z = @sin(angle) * half_width;
        const lean_x = (random.float(f32) - 0.5) * 0.3;
        const lean_z = (random.float(f32) - 0.5) * 0.3;
        const left = frame.at(offset_x - side_x, -0.05, offset_z - side_z);
        const right = frame.at(offset_x + side_x, -0.05, offset_z + side_z);
        const tip = frame.at(offset_x + lean_x, height, offset_z + lean_z);
        try appendTriangle(gpa, mesh, left, right, tip, color);
        try appendTriangle(gpa, mesh, right, left, tip, color);
    }
}

fn appendPrism(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    frame: Frame,
    bottom: f32,
    top: f32,
    radius: f32,
    color: Color,
) !void {
    for (0..sides) |index| {
        const a0 = std.math.tau * @as(f32, @floatFromInt(index)) / sides;
        const a1 = std.math.tau * @as(f32, @floatFromInt(index + 1)) / sides;
        const low0 = frame.at(@cos(a0) * radius, bottom, @sin(a0) * radius);
        const low1 = frame.at(@cos(a1) * radius, bottom, @sin(a1) * radius);
        const high0 = frame.at(@cos(a0) * radius, top, @sin(a0) * radius);
        const high1 = frame.at(@cos(a1) * radius, top, @sin(a1) * radius);
        try appendTriangle(gpa, mesh, low0, high1, low1, color);
        try appendTriangle(gpa, mesh, low0, high0, high1, color);
    }
}

fn appendCone(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    frame: Frame,
    base_height: f32,
    height: f32,
    radius: f32,
    color: Color,
) !void {
    const apex = frame.at(0, base_height + height, 0);
    const center = frame.at(0, base_height, 0);
    for (0..sides) |index| {
        const a0 = std.math.tau * @as(f32, @floatFromInt(index)) / sides;
        const a1 = std.math.tau * @as(f32, @floatFromInt(index + 1)) / sides;
        const rim0 = frame.at(@cos(a0) * radius, base_height, @sin(a0) * radius);
        const rim1 = frame.at(@cos(a1) * radius, base_height, @sin(a1) * radius);
        try appendTriangle(gpa, mesh, rim0, apex, rim1, color);
        try appendTriangle(gpa, mesh, rim0, rim1, center, color);
    }
}

fn appendTriangle(
    gpa: std.mem.Allocator,
    mesh: *Mesh,
    a: Vec3,
    b: Vec3,
    c: Vec3,
    color: Color,
) !void {
    const normal = nz.vec.normalize(nz.vec.cross(b - a, c - a));
    const base: u32 = @intCast(mesh.vertices.items.len);
    for ([_]Vec3{ a, b, c }) |corner| try mesh.vertices.append(gpa, .{
        .position = corner,
        .normal = normal,
        .color = .{ color[0], color[1], color[2], 1 },
    });
    try mesh.indices.appendSlice(gpa, &.{ base, base + 1, base + 2 });
}

fn scaled(color: Color, factor: f32) Color {
    return .{ color[0] * factor, color[1] * factor, color[2] * factor };
}
