const Camera = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const tracy = @import("ztracy");
const World = system.World;
const Options = @import("../Options.zig");
const Vec3 = nz.Vec3(f32);
const Quat = nz.quat.Hamiltonian(f32);

transform: nz.Transform3D(f32) = .{},

yaw_rotation: Quat = .identity,
pitch: f32 = 0,
boom_offset: Vec3 = .{ 0, 1.5, 8 },
arm_length: f32 = 1.5,
free_speed: f32 = 30,

pub const sensitivity: f32 = 0.02;
pub const camera_padding: f32 = 0.5;
pub const arm_ease_speed: f32 = 4;
pub const near: f32 = 0.01;
pub const far: f32 = 1000;

pub fn viewProj(self: *const Camera, fov_rad: f32, aspect: f32) nz.Mat4x4(f32) {
    const inv_rotation = self.transform.rotation.conjugate().toMat4x4();
    const inv_translation = nz.Mat4x4(f32).translate(-self.transform.position);
    const view = inv_rotation.mul(inv_translation);

    const f = 1.0 / std.math.tan(fov_rad / 2.0);
    const proj: nz.Mat4x4(f32) = .new(.{
        f / aspect, 0, 0, 0,
        0, -f, 0,                           0,
        0, 0,  far / (near - far),          -1,
        0, 0,  (far * near) / (near - far), 0,
    });
    return proj.mul(view);
}

pub fn update(self: *Camera, world: *World, options: *const Options, look_delta: @Vector(2, f64), input: shared.net.Input, wheel: f64) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    const mouse_sensitivity = sensitivity * options.mouse_sensitivity;
    const pitch_direction: f64 = if (options.invert_y) 1 else -1;
    const delta_yaw: f32 = @floatCast(-look_delta[0] * mouse_sensitivity);
    const delta_pitch: f32 = @floatCast(look_delta[1] * pitch_direction * mouse_sensitivity);
    const pitch_limit: f32 = std.math.degreesToRadians(80);

    if (world.controller.free_camera) {
        self.free_speed = std.math.clamp(self.free_speed * std.math.pow(f32, 1.2, @as(f32, @floatCast(wheel))), 1, 1000);
        if (nz.vec.length(self.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(self.transform.position);
            const yaw_quat: Quat = .angleAxis(delta_yaw, planet_up);
            self.yaw_rotation = yaw_quat.mul(self.yaw_rotation).normalize();
            self.pitch = std.math.clamp(self.pitch + delta_pitch, -pitch_limit, pitch_limit);
            const camera_forward = self.yaw_rotation.rotateVec(.{ 0, 0, -1 });
            const tangent_forward = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
            if (nz.vec.length(tangent_forward) > 0.0001) {
                self.yaw_rotation = .lookAt(tangent_forward, planet_up);
            }
        }
        const pitch_quat: Quat = .angleAxis(self.pitch, .{ 1, 0, 0 });
        const free_rotation = self.yaw_rotation.mul(pitch_quat).normalize();
        var direction: Vec3 = .{ 0, 0, 0 };
        if (input.keys.move_forward) direction[2] -= 1;
        if (input.keys.move_backward) direction[2] += 1;
        if (input.keys.move_right) direction[0] += 1;
        if (input.keys.move_left) direction[0] -= 1;
        if (input.keys.jump) direction[1] += 1;
        if (input.keys.move_down) direction[1] -= 1;
        if (nz.vec.length(direction) > 0) {
            const world_direction = free_rotation.rotateVec(nz.vec.normalize(direction));
            self.transform.position += nz.vec.scale(world_direction, self.free_speed * world.delta_time);
        }
        self.transform.rotation = free_rotation;
        return;
    }

    if (world.getPtr(world.player_id)) |player| {
        if (nz.vec.length(player.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(player.transform.position);
            const yaw_quat: Quat = .angleAxis(delta_yaw, planet_up);
            self.yaw_rotation = yaw_quat.mul(self.yaw_rotation).normalize();
            self.pitch = std.math.clamp(self.pitch + delta_pitch, -pitch_limit, pitch_limit);
            const camera_forward = self.yaw_rotation.rotateVec(.{ 0, 0, -1 });
            const tangent_forward = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
            if (nz.vec.length(tangent_forward) > 0.0001) {
                self.yaw_rotation = .lookAt(tangent_forward, planet_up);
            }
        }
        const pitch_quat: Quat = .angleAxis(self.pitch, .{ 1, 0, 0 });
        const final_rotation = self.yaw_rotation.mul(pitch_quat).normalize();
        const pivot = player.transform.position + self.yaw_rotation.rotateVec(.{ self.boom_offset[0], self.boom_offset[1], 0 });
        const arm_direction = final_rotation.rotateVec(.{ 0, 0, 1 });

        const clear_length = traceArm(pivot, arm_direction, self.boom_offset[2], &world.planet);
        if (clear_length < self.arm_length) {
            self.arm_length = clear_length;
        } else {
            self.arm_length += (clear_length - self.arm_length) * @min(1, arm_ease_speed * world.delta_time);
        }

        self.transform.position = pivot + nz.vec.scale(arm_direction, self.arm_length);
        self.transform.rotation = final_rotation;
    }
}

fn traceArm(pivot: Vec3, direction: Vec3, max_length: f32, planet: *const shared.Planet) f32 {
    if (planet.planet_radius == 0) return max_length;
    var distance: f32 = 0;
    for (0..32) |_| {
        if (distance >= max_length) return max_length;
        const clearance = planet.sdf(pivot + nz.vec.scale(direction, distance)) - camera_padding;
        if (clearance <= 0.01) return distance;
        distance += clearance;
    }
    return distance;
}
