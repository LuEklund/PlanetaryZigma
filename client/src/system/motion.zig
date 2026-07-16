const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Info = system.Info;
const nz = shared.numz;

pub fn evaluate(info: *const Info, server_time: f32) void {
    for (info.world.entities.values()) |*entity| {
        const motion = entity.update_motion orelse continue;
        const motion_time = @as(f32, @floatFromInt(motion.tick)) * shared.tick_seconds;
        const age = server_time - motion_time;
        const target = motion.position + nz.vec.scale(motion.velocity, age);

        if (motion.tick != entity.smoothed_moiton_tick) {
            entity.position_error = entity.transform.position - target;
            entity.smoothed_moiton_tick = motion.tick;
        }

        const error_decay = std.math.pow(f32, 1e-5, info.delta_time);
        entity.position_error = nz.vec.scale(entity.position_error, error_decay);
        entity.transform.position = target + entity.position_error;

        const target_rotation = nz.Quat(f32).fromVec(motion.rotation);
        const rotation_decay = std.math.pow(f32, 1e-5, info.delta_time);
        entity.transform.rotation = entity.transform.rotation.slerp(target_rotation, 1.0 - rotation_decay);
    }
}
