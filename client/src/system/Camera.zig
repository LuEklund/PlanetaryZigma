const nz = @import("shared").numz;
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const Info = system.Info;

fov_rad: f32 = 1.5,
transform: nz.Transform3D(f32) = .{},

yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
pitch: f32 = 0,
boom_offset: nz.Vec3(f32) = .{ 0, 0, 0 },

pub fn update(self: *@This(), info: *const Info, input_map: *shared.net.Input) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

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
