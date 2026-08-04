const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const Rendering = @import("render").Rendering;
const AssetServer = @import("render").AssetServer;
const Ui = @import("render").Ui;
const World = @import("../World.zig");
const Quat = shared.numz.quat.Hamiltonian(f32);
const nz = shared.numz;
const extract = @import("extract.zig");
const pause = @import("pause.zig");

/// Everything the --render debug window needs. Nothing outside this file exists in a
/// dedicated build — `System.viewer` is `void` when the render option is off.
rendering: Rendering,
camera: Camera,
ui: Ui,
paused: bool,

/// The fly camera the window looks through, and which player it is following.
pub const Camera = struct {
    position: nz.Vec3(f32),
    /// Yaw lives as a rotation rather than an angle because it turns around the planet's
    /// up vector, not the world Y axis — same as the player camera.
    yaw_rotation: Quat,
    pitch: f32,
    speed: f32,
    /// Entity id of the followed player, `.none` to fly. An id stays valid across
    /// roster changes, where an index would dangle on the first disconnect.
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

    /// F toggles follow, Q/E pick the player. Flying: the mouse looks, WASD moves,
    /// space/shift rise and fall, wheel changes speed.
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
};

pub fn init(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, window: *Window, asset_server: *AssetServer, world: *World) !void {
    try self.rendering.init(.{
        .gpa = gpa,
        .io = io,
        .window = window,
        .asset_server = asset_server,
    });
    errdefer self.rendering.deinit(gpa, io);

    self.ui = try .init(gpa, window.size.width, window.size.height);
    self.ui.default_font = &self.rendering.fonts[0];
    self.ui.texture_slots = &self.rendering.texture_slots;
    self.camera = .init(.{ 0, world.planet_radius * World.ship_room_altitude_factor, 30 });
    self.paused = false;
}

pub fn deinit(self: *Viewer, gpa: std.mem.Allocator, io: std.Io) void {
    self.ui.deinit(gpa);
    self.rendering.deinit(gpa, io);
}

/// Returns true when the window asks the server to stop.
pub fn draw(self: *Viewer, world: *World, io: std.Io) !bool {
    const window = self.rendering.window;
    try window.poll(.{ .text = null });

    if (window.keyboard.get(.escape) == .press) self.paused = !self.paused;
    if (self.paused or !window.focused) {
        try window.setPointerRelative(false);
        try window.setPointerConstraint(.none);
        try window.setPointerVisible(true);
    } else {
        try window.setPointerVisible(false);
        try window.setPointerConstraint(.locked);
        try window.setPointerRelative(true);
        self.camera.update(window, world.delta_time, world.players.items);
    }

    self.ui.screen_width = @floatFromInt(window.size.width);
    self.ui.screen_height = @floatFromInt(window.size.height);
    const pointer_position = switch (window.pointer.movement) {
        .position => |position| [2]f32{ @floatCast(position.x), @floatCast(position.y) },
        .relative => [2]f32{ 0, 0 },
    };
    self.ui.start(.{
        .position = .{ .left = pointer_position[0], .top = pointer_position[1] },
        .left_click = window.pointer.buttons.left,
        .right_click = window.pointer.buttons.right,
    }, world.delta_time);
    var quit = window.should_close;
    if (self.paused) switch (pause.update(&self.ui, world.players.items.len, std.mem.indexOfScalar(shared.entity.Id, world.players.items, self.camera.follow))) {
        .none => {},
        .resume_view => self.paused = false,
        .quit => quit = true,
    };
    self.ui.end();

    try extract.frame(world, &self.rendering, self.camera, &self.ui);
    try self.rendering.reloadIfChanged(io);
    return quit;
}
