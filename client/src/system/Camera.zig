const std = @import("std");
const nz = @import("shared").numz;
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const Vec3 = nz.Vec3(f32);
const Quat = nz.quat.Hamiltonian(f32);

pub const sensitivity: f32 = 0.02;
pub const default_boom_offset: Vec3 = .{ 0, 1.5, 8 };

fov_rad: f32 = 1.5,
transform: nz.Transform3D(f32) = .{},

yaw_rotation: Quat = .identity,
pitch: f32 = 0,
boom_offset: Vec3 = default_boom_offset,
free_speed: f32 = 30,

pub fn update(self: *@This(), info: *const Info) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const controller = &info.world.controller;
    const keys = controller.input_map.keys;
    const delta_yaw: f32 = @floatCast(-controller.mouse_delta[0] * sensitivity);
    const delta_pitch: f32 = @floatCast(-controller.mouse_delta[1] * sensitivity);
    const pitch_limit: f32 = std.math.pi / 2.0 - 0.01;

    if (controller.free_camera) {
        self.free_speed = std.math.clamp(self.free_speed * std.math.pow(f32, 1.2, @as(f32, @floatCast(controller.mouse_wheel))), 1, 1000);
        if (nz.vec.length(self.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(self.transform.position);
            if (keys.mouse_button_right) {
                const yaw_quat: Quat = .angleAxis(delta_yaw, planet_up);
                self.yaw_rotation = yaw_quat.mul(self.yaw_rotation).normalize();
                self.pitch = std.math.clamp(self.pitch + delta_pitch, -pitch_limit, pitch_limit);
            }
            const camera_forward = self.yaw_rotation.rotateVec(.{ 0, 0, -1 });
            const tangent_forward = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
            if (nz.vec.length(tangent_forward) > 0.0001) {
                self.yaw_rotation = .lookAt(tangent_forward, planet_up);
            }
        }
        const pitch_quat: Quat = .angleAxis(self.pitch, .{ 1, 0, 0 });
        const rotation = self.yaw_rotation.mul(pitch_quat).normalize();
        var direction: Vec3 = .{ 0, 0, 0 };
        if (keys.w) direction[2] -= 1;
        if (keys.s) direction[2] += 1;
        if (keys.d) direction[0] += 1;
        if (keys.a) direction[0] -= 1;
        if (keys.space) direction[1] += 1;
        if (keys.l_shift) direction[1] -= 1;
        if (nz.vec.length(direction) > 0) {
            const world_direction = rotation.rotateVec(nz.vec.normalize(direction));
            self.transform.position += nz.vec.scale(world_direction, self.free_speed * info.delta_time);
        }
        self.transform.rotation = rotation;
        return;
    }

    if (info.world.getPtr(info.world.player_id)) |player| {
        if (nz.vec.length(player.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(player.transform.position);
            self.boom_offset[2] += @floatCast(-controller.mouse_wheel);
            self.boom_offset[2] = std.math.clamp(self.boom_offset[2], 0, 1000);
            if (keys.mouse_button_right) {
                const yaw_quat: Quat = .angleAxis(delta_yaw, planet_up);
                self.yaw_rotation = yaw_quat.mul(self.yaw_rotation).normalize();
                self.pitch = std.math.clamp(self.pitch + delta_pitch, -pitch_limit, pitch_limit);
            }
            const camera_forward = self.yaw_rotation.rotateVec(.{ 0, 0, -1 });
            const tangent_forward = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
            if (nz.vec.length(tangent_forward) > 0.0001) {
                self.yaw_rotation = .lookAt(tangent_forward, planet_up);
            }
        }
        const pitch_quat: Quat = .angleAxis(self.pitch, .{ 1, 0, 0 });
        const final_rotation = self.yaw_rotation.mul(pitch_quat).normalize();
        const pivot = player.transform.position + self.yaw_rotation.rotateVec(.{ self.boom_offset[0], self.boom_offset[1], 0 });
        const arm = final_rotation.rotateVec(.{ 0, 0, self.boom_offset[2] });
        self.transform.position = pivot + arm;
        self.transform.rotation = final_rotation;
    }
    controller.input_map.camera_yaw_rotation = self.yaw_rotation.toVec();
}
