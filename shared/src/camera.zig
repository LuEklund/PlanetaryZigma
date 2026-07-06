const std = @import("std");
const nz = @import("numz");
const net = @import("net.zig");
const Vec3 = nz.Vec3(f32);
const Quat = nz.quat.Hamiltonian(f32);

pub const sensitivity: f32 = 1;
pub const default_boom_offset: Vec3 = .{ 0, 1, 8 };

pub fn look(
    yaw_rotation: *Quat,
    pitch: *f32,
    boom_offset: *Vec3,
    input: net.Input,
    planet_up: Vec3,
    delta_time: f32,
) void {
    boom_offset[2] += @floatCast(-input.mouse_wheel);
    boom_offset[2] = std.math.clamp(boom_offset[2], 0, 1000);

    const delta_yaw: f32 = @floatCast(-input.mouse_delta[0] * sensitivity * delta_time);
    const delta_pitch: f32 = @floatCast(-input.mouse_delta[1] * sensitivity * delta_time);

    if (input.keys.mouse_button_right) {
        const yaw_quat: Quat = .angleAxis(delta_yaw, planet_up);
        yaw_rotation.* = yaw_quat.mul(yaw_rotation.*).normalize();
        const pitch_limit: f32 = std.math.pi / 2.0 - 0.01;
        pitch.* = std.math.clamp(pitch.* + delta_pitch, -pitch_limit, pitch_limit);
    }

    const camera_up = nz.vec.normalize(yaw_rotation.rotateVec(.{ 0, 1, 0 }));
    const alignment = std.math.clamp(nz.vec.dot(camera_up, planet_up), -1.0, 1.0);
    if (alignment < 0.9999) {
        const camera_forward = nz.vec.normalize(yaw_rotation.rotateVec(.{ 0, 0, -1 }));
        const axis: Vec3 = if (alignment > -0.9999)
            nz.vec.normalize(nz.vec.cross(camera_up, planet_up))
        else
            nz.vec.normalize(nz.vec.cross(camera_up, camera_forward));
        const angle = std.math.acos(alignment);
        const align_quat: Quat = .angleAxis(angle, axis);
        yaw_rotation.* = align_quat.mul(yaw_rotation.*).normalize();
    }
}

pub fn boomTransform(yaw_rotation: Quat, pitch: f32, boom_offset: Vec3, player_position: Vec3) struct { position: Vec3, rotation: Quat } {
    const pitch_quat: Quat = .angleAxis(pitch, .{ 1, 0, 0 });
    const final_rotation = yaw_rotation.mul(pitch_quat).normalize();
    const pivot = player_position + yaw_rotation.rotateVec(.{ boom_offset[0], boom_offset[1], 0 });
    const arm = final_rotation.rotateVec(.{ 0, 0, boom_offset[2] });
    return .{ .position = pivot + arm, .rotation = final_rotation };
}
