const std = @import("std");
const nz = @import("numz");

pub const day_length_seconds: f32 = 240;
pub const sun_axis_tilt: f32 = 0.35;
pub const night_light: [3]f32 = .{ 0.22, 0.26, 0.4 };

pub fn sunDirection(server_seconds: f32) nz.Vec3(f32) {
    const angle = server_seconds / day_length_seconds * std.math.tau + 0.9;
    return nz.vec.normalize(
        @as(
            nz.Vec3(f32),
            .{ @cos(angle), @sin(angle) * @cos(sun_axis_tilt), @sin(angle) * @sin(sun_axis_tilt) },
        ),
    );
}

/// RoR2 loop variants, our way: looped stages (past `stages_per_loop`) run half a day ahead,
/// so a loop starts at night.
pub fn sunDirectionForStage(server_seconds: f32, stage: u32, stages_per_loop: u32) nz.Vec3(f32) {
    const looped = stage > stages_per_loop;
    return sunDirection(server_seconds + if (looped) day_length_seconds / 2 else 0);
}

pub fn daylight(sun_direction: nz.Vec3(f32), position: nz.Vec3(f32)) f32 {
    const length = nz.vec.length(position);
    if (length < 0.0001) return 1;
    const up = nz.vec.scale(position, 1 / length);
    const x = std.math.clamp((nz.vec.dot(sun_direction, up) + 0.10) / 0.35, 0, 1);
    return x * x * (3 - 2 * x);
}

pub fn lightColor(day: f32) [4]f32 {
    return .{
        std.math.lerp(night_light[0], 1, day),
        std.math.lerp(night_light[1], 1, day),
        std.math.lerp(night_light[2], 1, day),
        1,
    };
}
