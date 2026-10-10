const std = @import("std");
const nz = @import("numz");
const noise = @import("../noise.zig");
const Field = @import("Field.zig");
const Biome = @import("../Biome.zig");

pub const noise_amplitude = Field.max_height;

const full_height_radius = 100;

/// Off until caves have a gameplay use (Lucas 2026-10-10): they cost chunk-gen time.
pub const caves_enabled = false;
/// Caves live in this band under the outer surface; deeper is solid.
pub const cave_depth: comptime_int = if (caves_enabled) 24 else 0;
/// Tunnel paths: where this surface noise crosses zero.
const path_frequency: f32 = 0.012;
/// Tunnel center depth: slow surface noise, so floors slope gently (~10-25 degrees).
const depth_frequency: f32 = 0.006;
const half_width: f32 = 3;
const half_height: f32 = 2.5;
/// Rough |gradient| of simplex noise per unit frequency, turns noise into meters.
const noise_gradient: f32 = 2.5;

/// Terrain with caves carved out. Everything that collides or meshes uses this.
pub fn sdf(position: nz.Vec3(f32), planet_radius: f32) f32 {
    const outer = terrain(position, planet_radius);
    if (!caves_enabled) return outer;
    const depth = -outer;
    if (depth < -1 or depth > cave_depth or planet_radius < full_height_radius) return outer;
    return @max(outer, -cave(position, planet_radius, depth));
}

fn caveShift(planet_radius: f32) nz.Vec3(f32) {
    return @splat(@mod(planet_radius * 71, 512) + 2048);
}

/// Depth of the tunnel center under a surface point; negative = the tunnel is open to the sky.
fn centerDepth(on_surface: nz.Vec3(f32), shift: nz.Vec3(f32)) f32 {
    const slow = nz.vec.scale(on_surface, depth_frequency) - shift;
    const max_center: f32 = cave_depth - half_height - 2;
    return (noise.simplex3(slow[0], slow[1], slow[2]) * 0.7 + 0.3) * max_center;
}

/// Approximate signed distance to the nearest tunnel (meters), negative inside one.
/// A tunnel whose center depth goes above ground opens as a ramp: that is an entrance.
fn cave(position: nz.Vec3(f32), planet_radius: f32, depth: f32) f32 {
    const shift = caveShift(planet_radius);
    const on_surface = nz.vec.scale(nz.vec.normalize(position), planet_radius);
    const path = nz.vec.scale(on_surface, path_frequency) + shift;
    const sideways = noise.simplex3(path[0], path[1], path[2]) / (path_frequency * noise_gradient);
    const vertical = (depth - centerDepth(on_surface, shift)) * (half_width / half_height);
    return @sqrt(sideways * sideways + vertical * vertical) - half_width;
}

/// The outer surface only (no caves): spawns, props, water and nav snapping use this.
pub fn terrain(position: nz.Vec3(f32), planet_radius: f32) f32 {
    const surface_point = nz.vec.scale(nz.vec.normalize(position), planet_radius);
    const height_scale = @min(planet_radius / full_height_radius, 1);
    const biome = Biome.forRadius(@intFromFloat(planet_radius));
    var height: f32 = 0;
    inline for (Field.fields, 0..) |field, index| {
        const shift: f32 = @mod(planet_radius * 137, 1024) + @as(f32, @floatFromInt(index)) * 512;
        const sample = nz.vec.scale(
            surface_point,
            field.frequency * biome.frequency_scale,
        ) + @as(nz.Vec3(f32), @splat(shift));
        height += field.evaluate(
            noise.simplex3(sample[0], sample[1], sample[2]),
        ) * biome.field_scale[index];
    }
    return nz.vec.length(position) - planet_radius - height * height_scale;
}

pub fn gradient(position: nz.Vec3(f32), planet_radius: f32) nz.Vec3(f32) {
    const epsilon: f32 = 0.05;
    return .{
        (sdf(
            position + nz.Vec3(f32){ epsilon, 0, 0 },
            planet_radius,
        ) - sdf(position - nz.Vec3(f32){ epsilon, 0, 0 }, planet_radius)) / (2 * epsilon),
        (sdf(
            position + nz.Vec3(f32){ 0, epsilon, 0 },
            planet_radius,
        ) - sdf(position - nz.Vec3(f32){ 0, epsilon, 0 }, planet_radius)) / (2 * epsilon),
        (sdf(
            position + nz.Vec3(f32){ 0, 0, epsilon },
            planet_radius,
        ) - sdf(position - nz.Vec3(f32){ 0, 0, epsilon }, planet_radius)) / (2 * epsilon),
    };
}

pub fn sampled(position: nz.Vec3(f32), planet_radius: f32) f32 {
    const base = @floor(position);
    const fraction = position - base;
    var values: [8]f32 = undefined;
    for (&values, 0..) |*value, corner| {
        const offset: nz.Vec3(f32) = .{
            @floatFromInt(corner & 1),
            @floatFromInt((corner >> 1) & 1),
            @floatFromInt((corner >> 2) & 1),
        };
        value.* = sdf(base + offset, planet_radius);
    }
    const y0z0 = std.math.lerp(values[0], values[1], fraction[0]);
    const y1z0 = std.math.lerp(values[2], values[3], fraction[0]);
    const y0z1 = std.math.lerp(values[4], values[5], fraction[0]);
    const y1z1 = std.math.lerp(values[6], values[7], fraction[0]);
    const z0 = std.math.lerp(y0z0, y1z0, fraction[1]);
    const z1 = std.math.lerp(y0z1, y1z1, fraction[1]);
    return std.math.lerp(z0, z1, fraction[2]);
}

test "caves carve only inside the band under the surface" {
    if (!caves_enabled) return error.SkipZigTest;
    const planet_radius: f32 = 1000;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var carved_in_band: u32 = 0;
    for (0..4000) |_| {
        const direction = nz.vec.normalize(nz.Vec3(f32){
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });
        const surface = planet_radius + noise_amplitude;
        const deep = nz.vec.scale(direction, surface - noise_amplitude * 2 - cave_depth - 4);
        try std.testing.expectEqual(terrain(deep, planet_radius), sdf(deep, planet_radius));
        const band = nz.vec.scale(direction, planet_radius - random.float(f32) * cave_depth * 0.6);
        const solid = terrain(band, planet_radius) < 0;
        if (solid and sdf(band, planet_radius) > 0) carved_in_band += 1;
    }
    try std.testing.expect(carved_in_band > 40);
}

test "tunnel floors slope gently" {
    if (!caves_enabled) return error.SkipZigTest;
    const planet_radius: f32 = 1000;
    const shift = caveShift(planet_radius);
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    var steepest: f32 = 0;
    for (0..4000) |_| {
        const direction = nz.vec.normalize(nz.Vec3(f32){
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
            random.float(f32) - 0.5,
        });
        const here = nz.vec.scale(direction, planet_radius);
        const step = nz.vec.normalize(nz.vec.cross(direction, .{ 0.3, 1, 0.2 }));
        const rise = centerDepth(here + step, shift) - centerDepth(here, shift);
        steepest = @max(steepest, @abs(rise));
    }
    try std.testing.expect(steepest < 0.55);
}
