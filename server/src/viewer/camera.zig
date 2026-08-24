const Camera = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const nz = shared.numz;
const Quat = nz.quat.Hamiltonian(f32);

position: nz.Vec3(f32),
yaw_rotation: Quat,
pitch: f32,
speed: f32,
follow: shared.entity.Id,

const pitch_limit: f32 = std.math.degreesToRadians(80);
const look_sensitivity: f32 = 0.0025;

pub fn init(position: nz.Vec3(f32)) Camera {
    return .{ .position = position, .yaw_rotation = .identity, .pitch = 0, .speed = 20, .follow = .none };
}

pub fn rotation(self: Camera) Quat {
    const pitch_quat: Quat = .angleAxis(self.pitch, .{ 1, 0, 0 });
    return self.yaw_rotation.mul(pitch_quat).normalize();
}

pub fn update(self: *Camera, window: *Window, delta_time: f32, players: []const shared.entity.Id) void {
    if (window.keyboard.get(.f) == .press) self.follow = if (self.follow == .none and players.len > 0) players[0] else .none;
    if (self.follow != .none and players.len == 0) self.follow = .none;
    if (self.follow != .none) {
        var index = std.mem.indexOfScalar(shared.entity.Id, players, self.follow) orelse 0;
        if (window.keyboard.get(.e) == .press) index = (index + 1) % players.len;
        if (window.keyboard.get(.q) == .press) index = (index + players.len - 1) % players.len;
        self.follow = players[index];
        return;
    }

    self.speed = std.math.clamp(self.speed * std.math.pow(f32, 1.2, @as(f32, @floatCast(window.pointer.axis.vertical))), 1, 1000);

    const look = switch (window.pointer.movement) {
        .relative => |relative| nz.Vec3(f32){ @floatCast(relative.dx), @floatCast(relative.dy), 0 },
        .position => nz.Vec3(f32){ 0, 0, 0 },
    };
    if (nz.vec.length(self.position) > 0.001) {
        const planet_up = nz.vec.normalize(self.position);
        const yaw_quat: Quat = .angleAxis(-look[0] * look_sensitivity, planet_up);
        self.yaw_rotation = yaw_quat.mul(self.yaw_rotation).normalize();
        self.pitch = std.math.clamp(self.pitch - look[1] * look_sensitivity, -pitch_limit, pitch_limit);
        const camera_forward = self.yaw_rotation.rotateVec(.{ 0, 0, -1 });
        const tangent_forward = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
        if (nz.vec.length(tangent_forward) > 0.0001) {
            self.yaw_rotation = .lookAt(tangent_forward, planet_up);
        }
    }

    var direction: nz.Vec3(f32) = .{ 0, 0, 0 };
    if (window.keyboard.isDown(.w)) direction[2] -= 1;
    if (window.keyboard.isDown(.s)) direction[2] += 1;
    if (window.keyboard.isDown(.a)) direction[0] -= 1;
    if (window.keyboard.isDown(.d)) direction[0] += 1;
    if (window.keyboard.isDown(.space)) direction[1] += 1;
    if (window.keyboard.isDown(.left_shift)) direction[1] -= 1;
    if (nz.vec.length(direction) == 0) return;

    const world_direction = self.rotation().rotateVec(nz.vec.normalize(direction));
    self.position += nz.vec.scale(world_direction, self.speed * delta_time);
}
