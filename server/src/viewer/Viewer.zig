const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const renderer_contract = @import("renderer_contract");
const graphics = @import("graphics");
const Particle = @import("graphics").Particle;
const dvui = @import("dvui");
const DvuiBackend = @import("dvui_backend");
const DvuiInput = @import("dvui_input");
const DrawList = renderer_contract.DrawList;
const World = @import("../World.zig");
const extract = @import("extract.zig");
pub const Camera = @import("camera.zig");
const menu = @import("menu.zig");

render: shared.HotLib(renderer_contract.Api, *anyopaque),
draw_list: DrawList,
window: *Window,
assets: graphics.Assets,
animator: graphics.Animator,
animations: std.AutoHashMapUnmanaged(shared.entity.Id, graphics.Animator.Handle),
particles: Particle,
camera: Camera,
dvui_backend: DvuiBackend,
dvui_window: dvui.Window,
dvui_input: DvuiInput,
menu_open: bool,
arrow_lines: std.ArrayList(DrawList.Line),
border_lines: std.ArrayList(DrawList.Line),
arrow_lines_field: ?u1,
border_lines_field: ?u1,

pub fn init(
    self: *Viewer,
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    planet_radius: f32,
) !void {
    self.animator = try .init(gpa);
    errdefer self.animator.deinit();
    self.animations = .empty;
    self.particles.clear();

    self.window = window;
    self.render = try .init("render", gpa, io);
    errdefer self.render.deinit(io);
    self.render.handle = self.render.api.init(&renderer_contract.InitOptions{
        .gpa = gpa,
        .io = io,
        .window = @ptrCast(window),
    }) orelse return error.RenderInit;
    errdefer self.render.api.deinit(self.render.handle);

    self.assets = try .init(gpa, io);
    errdefer self.assets.deinit(gpa, io);

    self.draw_list = try .init(gpa);
    errdefer self.draw_list.deinit(gpa);

    try self.assets.update(gpa, io, &self.render);

    self.dvui_backend = .{
        .io = io,
        .size = .{ .w = @floatFromInt(window.size.width), .h = @floatFromInt(window.size.height) },
        .scale = 1,
        .text_input_wanted = false,
        .frame = null,
    };
    self.dvui_input = .{ .buttons = .{}, .position = .{ .x = 0, .y = 0 } };
    self.dvui_window = try .init(
        @src(),
        gpa,
        self.dvui_backend.backend(),
        .{ .color_scheme = .dark, .keybinds = .none },
    );
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
    self.dvui_window.deinit();
    self.draw_list.deinit(gpa);
    self.animations.deinit(gpa);
    self.animator.deinit();
    self.assets.deinit(gpa, io);
    self.render.api.deinit(self.render.handle);
    self.render.deinit(io);
}

pub fn draw(self: *Viewer, world: *World, gpa: std.mem.Allocator, io: std.Io) !bool {
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

    self.dvui_backend.size = .{
        .w = @floatFromInt(window.size.width),
        .h = @floatFromInt(window.size.height),
    };
    self.dvui_backend.scale = std.math.clamp(self.dvui_backend.size.h / 1080, 0.5, 3);
    self.dvui_backend.frame = .{
        .draw_list = &self.draw_list,
        .render_api = &self.render.api,
        .render_handle = self.render.handle,
    };
    self.dvui_window.backend = self.dvui_backend.backend();
    try self.dvui_input.push(&self.dvui_window, window, "", &.{});
    try self.dvui_window.begin(self.dvui_backend.nanoTime());
    var quit = window.should_close;
    if (self.menu_open and menu.update(
        world,
        std.mem.indexOfScalar(shared.entity.Id, world.players.items, self.camera.follow),
    ))
        quit = true;
    dvui.label(@src(), "debug vertices {d}/{d}", .{
        (self.arrow_lines.items.len + self.border_lines.items.len) * 2,
        DrawList.max_lines * 2,
    }, .{
        .rect = .{ .x = 8, .y = 8, .w = 400, .h = 22 },
        .padding = .all(0),
        .font = dvui.Font.theme(.body).withSize(16),
    });
    _ = try self.dvui_window.end(.{});

    if (world.options.draw_flow_field and self.arrow_lines_field != world.navmesh.internal.active) {
        try extract.collectNavmeshArrows(world, gpa, &self.arrow_lines);
        self.arrow_lines_field = world.navmesh.internal.active;
    }
    if (world.options.draw_chunk_borders and self.border_lines_field != world.navmesh.internal.active) {
        try extract.collectChunkBorders(world, gpa, &self.border_lines);
        self.border_lines_field = world.navmesh.internal.active;
    }

    try extract.frame(world, self, gpa);
    self.render.trySwap(io);
    self.assets.update(gpa, io, &self.render) catch |err| std.log.err("assets: {t}", .{err});
    return quit;
}
