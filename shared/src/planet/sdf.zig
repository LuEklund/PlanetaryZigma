const std = @import("std");
const nz = @import("numz");
const noise = @import("../noise.zig");
const Field = @import("Field.zig");

pub const noise_amplitude = Field.max_height;

const full_height_radius = 100;

pub fn sdf(position: nz.Vec3(f32), planet_radius: f32) f32 {
    const surface_point = nz.vec.scale(nz.vec.normalize(position), planet_radius);
    const height_scale = @min(planet_radius / full_height_radius, 1);
    var height: f32 = 0;
    inline for (Field.fields, 0..) |field, index| {
        const shift: f32 = planet_radius * 137 + @as(f32, @floatFromInt(index)) * 512;
        const sample = nz.vec.scale(surface_point, field.frequency) + @as(nz.Vec3(f32), @splat(shift));
        height += field.evaluate(noise.simplex3(sample[0], sample[1], sample[2]));
    }
    return nz.vec.length(position) - planet_radius - height * height_scale;
}

pub fn gradient(position: nz.Vec3(f32), planet_radius: f32) nz.Vec3(f32) {
    const epsilon: f32 = 0.05;
    return .{
        (sdf(position + nz.Vec3(f32){ epsilon, 0, 0 }, planet_radius) - sdf(position - nz.Vec3(f32){ epsilon, 0, 0 }, planet_radius)) / (2 * epsilon),
        (sdf(position + nz.Vec3(f32){ 0, epsilon, 0 }, planet_radius) - sdf(position - nz.Vec3(f32){ 0, epsilon, 0 }, planet_radius)) / (2 * epsilon),
        (sdf(position + nz.Vec3(f32){ 0, 0, epsilon }, planet_radius) - sdf(position - nz.Vec3(f32){ 0, 0, epsilon }, planet_radius)) / (2 * epsilon),
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
