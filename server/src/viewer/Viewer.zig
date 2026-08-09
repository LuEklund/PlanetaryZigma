const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const render = @import("contract");
const render_system = @import("render_system");
const Emitter = @import("render_system").Emitter;
const AssetServer = @import("assets").AssetServer;
const Ui = @import("ui");
const DrawList = @import("contract").DrawList;
const World = @import("../World.zig");
const Quat = shared.numz.quat.Hamiltonian(f32);
const nz = shared.numz;
const extract = @import("extract.zig");
pub const Camera = @import("camera.zig");
const menu = @import("menu.zig");

render_lib: shared.HotLib(render.Renderer.VTable, *anyopaque, "init", "reload"),
renderer: render.Renderer,
draw_list: DrawList,
window: *Window,
assets: render_system.Assets,
animator: render_system.Animator,
emitters: Emitter.List,
camera: Camera,
ui: Ui,
menu_open: bool,
arrow_lines: std.ArrayList(DrawList.Line),
border_lines: std.ArrayList(DrawList.Line),
arrow_lines_field: ?u1,
border_lines_field: ?u1,

pub fn init(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, window: *Window, asset_server: *AssetServer, planet_radius: f32) !void {
    try self.assets.init(gpa, asset_server, &self.renderer);
    errdefer self.assets.deinit(gpa);
    self.animator = try .init(gpa);
    errdefer self.animator.deinit();
    self.emitters = @splat(Emitter.free);

    self.window = window;
    self.render_lib = try .init("render", io);
    errdefer self.render_lib.deinit(io);
    self.renderer = .{
        .vtable = &self.render_lib.symbols,
        .userdata = self.render_lib.symbols.init(&render.Renderer.InitOptions{
            .gpa = gpa,
            .io = io,
            .window = @ptrCast(window),
            .first_dynamic_texture_slot = @intCast(shared.Texture.count()),
        }) orelse return error.RenderInit,
    };
    errdefer self.renderer.vtable.deinit(self.renderer.userdata);

    self.draw_list = try .init(gpa);
    errdefer self.draw_list.deinit(gpa);

    try asset_server.load();
    self.assets.uploadGenerated(&self.renderer);

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
    self.draw_list.deinit(gpa);
    self.animator.deinit();
    // Before the renderer: freeing a model's images is a call INTO render.so.
    self.assets.deinit(gpa);
    self.renderer.vtable.deinit(self.renderer.userdata);
    self.render_lib.deinit(io);
}

/// Returns true when the window asks the server to stop.
pub fn draw(self: *Viewer, world: *World, io: std.Io) !bool {
    const window = self.window;
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
    }, &self.assets.fonts[0], world.delta_time);
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
    try self.render_lib.trySwap(io, self.renderer.userdata);
    return quit;
}
