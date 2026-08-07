const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const Renderer = @import("render").Renderer;
const AssetServer = @import("render").AssetServer;
const Ui = @import("render").Ui;
const DrawList = @import("render").DrawList;
const World = @import("../World.zig");
const Quat = shared.numz.quat.Hamiltonian(f32);
const nz = shared.numz;
const extract = @import("extract.zig");
pub const Camera = @import("camera.zig");
const menu = @import("menu.zig");

renderer: Renderer,
camera: Camera,
ui: Ui,
menu_open: bool,
arrow_lines: std.ArrayList(DrawList.Line),
border_lines: std.ArrayList(DrawList.Line),
arrow_lines_field: ?u1,
border_lines_field: ?u1,

pub fn init(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, window: *Window, asset_server: *AssetServer, planet_radius: f32) !void {
    try self.renderer.init(.{
        .gpa = gpa,
        .io = io,
        .window = window,
        .asset_server = asset_server,
    });
    errdefer self.renderer.deinit(gpa, io);

    self.ui = try .init(gpa, window.size.width, window.size.height);
    self.camera = .init(.{ 0, planet_radius * World.ship_room_altitude_factor, 30 });
    self.menu_open = true;
    self.arrow_lines = .empty;
    self.border_lines = .empty;
    self.arrow_lines_field = null;
    self.border_lines_field = null;
}

pub fn deinit(self: *Viewer, gpa: std.mem.Allocator, io: std.Io) void {
    self.arrow_lines.deinit(gpa);
    self.border_lines.deinit(gpa);
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
    }, &self.renderer.fonts[0], &self.renderer.texture_slots, world.delta_time);
    var quit = window.should_close;
    if (self.menu_open and menu.update(&self.ui, world, std.mem.indexOfScalar(shared.entity.Id, world.players.items, self.camera.follow)))
        quit = true;
    self.ui.addText(null, self.ui.print("debug vertices {d}/{d}", .{
        (self.arrow_lines.items.len + self.border_lines.items.len) * 2,
        DrawList.max_lines * 2,
    }), 16, 8, 8);
    self.ui.end();

    if (world.options.draw_flow_field and self.arrow_lines_field != world.navmesh.internal.active) {
        try extract.collectNavmeshArrows(world, world.gpa, &self.arrow_lines);
        self.arrow_lines_field = world.navmesh.internal.active;
    }
    if (world.options.draw_chunk_borders and self.border_lines_field != world.navmesh.internal.active) {
        try extract.collectChunkBorders(world, world.gpa, &self.border_lines);
        self.border_lines_field = world.navmesh.internal.active;
    }

    try extract.frame(world, self);
    try self.renderer.reloadIfChanged(io);
    return quit;
}
