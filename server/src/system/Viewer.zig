const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const Renderer = @import("render").Renderer;
const AssetServer = @import("render").AssetServer;
const Ui = @import("render").Ui;
const World = @import("../World.zig");
const Quat = shared.numz.quat.Hamiltonian(f32);
const nz = shared.numz;
const extract = @import("extract.zig");
pub const Camera = @import("viewer_camera.zig");
const menu = @import("menu.zig");

renderer: Renderer,
camera: Camera,
ui: Ui,
menu_open: bool,

pub fn init(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, window: *Window, asset_server: *AssetServer, world: *World) !void {
    try self.renderer.init(.{
        .gpa = gpa,
        .io = io,
        .window = window,
        .asset_server = asset_server,
    });
    errdefer self.renderer.deinit(gpa, io);

    self.ui = try .init(gpa, window.size.width, window.size.height);
    self.ui.default_font = &self.renderer.fonts[0];
    self.ui.texture_slots = &self.renderer.texture_slots;
    self.camera = .init(.{ 0, world.planet_radius * World.ship_room_altitude_factor, 30 });
    self.menu_open = false;
}

pub fn deinit(self: *Viewer, gpa: std.mem.Allocator, io: std.Io) void {
    self.ui.deinit(gpa);
    self.renderer.deinit(gpa, io);
}

/// Returns true when the window asks the server to stop.
pub fn draw(self: *Viewer, world: *World, io: std.Io) !bool {
    const window = self.renderer.window;
    try window.poll(.{ .text = null });

    if (window.keyboard.get(.escape) == .press) self.menu_open = !self.menu_open;
    if (self.menu_open or !window.focused) {
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
    if (self.menu_open) switch (menu.update(&self.ui, world.players.items.len, std.mem.indexOfScalar(shared.entity.Id, world.players.items, self.camera.follow))) {
        .none => {},
        .close => self.menu_open = false,
        .quit => quit = true,
    };
    self.ui.end();

    try extract.frame(world, &self.renderer, self.camera, &self.ui);
    try self.renderer.reloadIfChanged(io);
    return quit;
}
