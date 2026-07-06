const std = @import("std");
const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;

fov_rad: f32 = 1.5,
transform: nz.Transform3D(f32) = .{},

yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
pitch: f32 = 0,
boom_offset: nz.Vec3(f32) = shared.camera.default_boom_offset,
free_speed: f32 = 30,

pub fn update(self: *@This(), info: *const Info, input_map: *shared.net.Input) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.controller.free_camera) {
        self.free_speed = std.math.clamp(self.free_speed * std.math.pow(f32, 1.2, @as(f32, @floatCast(input_map.mouse_wheel))), 1, 1000);
        var look_input = input_map.*;
        look_input.mouse_wheel = 0;
        if (nz.vec.length(self.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(self.transform.position);
            shared.camera.look(&self.yaw_rotation, &self.pitch, &self.boom_offset, look_input, planet_up, info.delta_time);
        }
        const pose = shared.camera.boomTransform(self.yaw_rotation, self.pitch, .{ 0, 0, 0 }, self.transform.position);
        var direction: nz.Vec3(f32) = .{ 0, 0, 0 };
        if (input_map.keys.w) direction[2] -= 1;
        if (input_map.keys.s) direction[2] += 1;
        if (input_map.keys.d) direction[0] += 1;
        if (input_map.keys.a) direction[0] -= 1;
        if (input_map.keys.space) direction[1] += 1;
        if (input_map.keys.l_shift) direction[1] -= 1;
        if (nz.vec.length(direction) > 0) {
            const world_direction = pose.rotation.rotateVec(nz.vec.normalize(direction));
            self.transform.position += nz.vec.scale(world_direction, self.free_speed * info.delta_time);
        }
        self.transform.rotation = pose.rotation;
        return;
    }

    if (info.world.getPtr(info.world.player_id)) |player| {
        if (nz.vec.length(player.transform.position) > 0.001) {
            const planet_up = nz.vec.normalize(player.transform.position);
            shared.camera.look(&self.yaw_rotation, &self.pitch, &self.boom_offset, input_map.*, planet_up, info.delta_time);
        }
    }
    input_map.camera_yaw_rotation = self.yaw_rotation.toVec();
}

pub fn applyPose(self: *@This(), player_position: nz.Vec3(f32)) void {
    const pose = shared.camera.boomTransform(self.yaw_rotation, self.pitch, self.boom_offset, player_position);
    self.transform.position = pose.position;
    self.transform.rotation = pose.rotation;
}
