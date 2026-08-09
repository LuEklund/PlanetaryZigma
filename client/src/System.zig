const System = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const NetworkManager = @import("system/NetworkManager.zig");
pub const AssetServer = @import("assets").AssetServer;
const render_system = @import("render_system");
const Emitter = @import("render_system").Emitter;
const motion = @import("system/motion.zig");
const extract = @import("system/extract.zig");
const render = @import("render");
const DrawList = @import("render").DrawList;

const menu_world = @import("system/menu.zig");
const particle_lab = @import("system/particle_lab.zig");

pub const Chat = @import("system/Chat.zig");
const Hud = @import("system/Hud.zig");

pub const std_options: std.Options = .{ .logFn = shared.logFn };

pub const Scene = enum {
    menu,
    game,
    particle_lab,
};

pub const World = @import("World.zig");
pub const Entity = World.Entity;

gpa: std.mem.Allocator,
io: std.Io,
window: *Window,
asset_server: *AssetServer,
render_lib: shared.HotLib(render.Renderer.VTable, *anyopaque, "init", "reload"),
renderer: render.Renderer,
draw_list: DrawList,
assets: render_system.Assets,
animator: render_system.Animator,
emitters: Emitter.List,
network_manager: NetworkManager,
scene: Scene,
hud: Hud,
request_exit: bool = false,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    asset_server: *AssetServer,
    world: *World,
    steam_client: *shared.SteamNet.Client,
};

pub fn init(self: *System, data: Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.window = data.window;
    self.asset_server = data.asset_server;

    try self.assets.init(data.gpa, data.asset_server, &self.renderer);
    errdefer self.assets.deinit(data.gpa);
    self.animator = try .init(data.gpa);
    errdefer self.animator.deinit();
    self.emitters = @splat(Emitter.free);

    self.render_lib = try .init("render", data.io);
    errdefer self.render_lib.deinit(data.io);
    self.renderer = .{
        .vtable = &self.render_lib.symbols,
        .userdata = self.render_lib.symbols.init(&render.Renderer.InitOptions{
            .gpa = data.gpa,
            .io = data.io,
            .window = data.window,
            .first_dynamic_texture_slot = @intCast(shared.Texture.count()),
        }) orelse return error.RenderInit,
    };
    errdefer self.renderer.vtable.deinit(self.renderer.userdata);

    self.draw_list = try .init(data.gpa);
    errdefer self.draw_list.deinit(data.gpa);

    // render.so is up, so parsing can start; the uploads drain on the first frame.
    try data.asset_server.load();
    self.assets.uploadGenerated(&self.renderer);

    try self.hud.init(data.gpa, data.window.size);
    errdefer self.hud.deinit(data.gpa);
    try self.network_manager.init(data.gpa, data.io, data.steam_client);
    errdefer self.network_manager.deinit();
    try self.enterScene(data.world, .menu);
    self.request_exit = false;
}

pub fn deinit(self: *System) void {
    self.network_manager.deinit();
    self.hud.deinit(self.gpa);
    self.draw_list.deinit(self.gpa);
    self.animator.deinit();
    // Before the renderer: freeing a model's images is a call INTO render.so.
    self.assets.deinit(self.gpa);
    self.renderer.vtable.deinit(self.renderer.userdata);
    self.render_lib.deinit(self.io);
}

fn enterScene(self: *System, world: *World, next: Scene) !void {
    world.clear();
    self.animator.clear();
    self.emitters = @splat(Emitter.free);
    self.hud.resetScreen();
    switch (next) {
        .menu => try menu_world.populate(world),
        .game => {},
        .particle_lab => try particle_lab.populate(world),
    }
    self.scene = next;
}

pub fn update(self: *System, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    world.planet.clearOutboxes();
    var text_buffer: [1024]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buffer);
    try self.window.poll(.{ .text = if (world.chat.open) &text_writer else null });
    try self.handleInput(world, text_buffer[0..text_writer.end]);
    const paused_before_hud = self.hud.overlay != .none;
    if (self.scene == .menu) menu_world.update(world);
    if (self.scene == .particle_lab) particle_lab.update(&self.emitters, world.elapsed_time);
    switch (try self.hud.update(world, self.scene, &self.network_manager, &world.options, &self.assets.fonts[0])) {
        .none => {},
        .main_menu => try self.network_manager.returnToMainMenu(),
        .quit => self.request_exit = true,
    }
    if (paused_before_hud or self.hud.overlay != .none or world.chat.open) {
        world.controller.clearInput();
    }
    try self.applyOptions(world);
    try self.network_manager.update(world);
    const next_scene: Scene = if (self.network_manager.connected()) .game else .menu;
    if (self.scene != .particle_lab and next_scene != self.scene) try self.enterScene(world, next_scene);
    try world.flush();
    for (world.entities.values()) |*entity| {
        entity.stun_time = @max(0, entity.stun_time - world.delta_time);
    }

    try world.planet.update(
        world.gpa,
        &.{if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position},
        @intFromFloat(@max(1.0, @round(world.options.chunk_view_distance))),
    );
    try extract.frame(self, world, self.scene != .particle_lab);
    self.render_lib.trySwap(self.io, self.renderer.userdata) catch |err| std.log.err("render swap: {s}", .{@errorName(err)});
    try self.asset_server.reloadChangedAssets();

    const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
    motion.evaluate(world, server_time);

    if (!paused_before_hud and self.hud.overlay == .none) world.camera.update(world, &world.options);
    world.controller.resetMouseDelta();
    world.controller.mouse_wheel = 0;
}

fn handleInput(self: *System, world: *World, typed: []const u8) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const window = self.window;
    self.hud.ui.screen_width = @floatFromInt(window.size.width);
    self.hud.ui.screen_height = @floatFromInt(window.size.height);
    const keyboard = window.keyboard;
    if (world.controller.rebinding_action != null) {
        world.controller.update(window);
        return;
    }
    if (self.scene == .game and self.hud.overlay == .none) {
        if (world.chat.open) {
            world.chat.handleText(typed);
            if (keyboard.get(.escape) == .press) world.controller.suppress_escape_release = true;
            world.chat.handleKeyboard(keyboard);
            return;
        } else if (keyboard.get(Chat.open_key) == .release) {
            world.chat.open = true;
            world.controller.clearInput();
            return;
        }
    }
    const escape_released = keyboard.get(.escape) == .release;
    if (escape_released and world.controller.suppress_escape_release) {
        world.controller.suppress_escape_release = false;
        return;
    }
    if (escape_released and self.hud.overlay == .options) {
        self.hud.overlay = if (self.hud.overlay.options.return_to_pause and self.scene == .game) .pause else .none;
        world.controller.clearInput();
        world.controller.resetMouseDelta();
        return;
    }
    if (escape_released and self.scene == .game) {
        self.hud.overlay = if (self.hud.overlay == .pause) .none else .pause;
        world.controller.clearInput();
        world.controller.resetMouseDelta();
        return;
    }
    if (escape_released and self.scene == .particle_lab) {
        try self.enterScene(world, .menu);
        return;
    }
    if (escape_released) {
        self.request_exit = true;
        return;
    }
    if (keyboard.get(.f4) == .release and self.scene == .menu) {
        try self.enterScene(world, .particle_lab);
        return;
    }
    world.controller.update(window);
}

fn applyOptions(self: *System, world: *World) !void {
    try self.window.setFullscreen(world.options.fullscreen);
    const wants_cursor_lock = self.scene == .game and self.hud.overlay == .none and self.window.focused;
    const was_locked = self.window.pointer.constraint == .locked;
    if (wants_cursor_lock) {
        try self.window.setPointerVisible(false);
        try self.window.setPointerConstraint(.locked);
        try self.window.setPointerRelative(true);
        if (!was_locked) world.controller.resetMouseDelta();
    } else {
        try self.window.setPointerRelative(false);
        try self.window.setPointerConstraint(.none);
        try self.window.setPointerVisible(true);
    }
}

fn reload(self: *System, pre_reload: bool) !void {
    // Each .so image has its own copy of shared's globals, so a fresh one starts with a
    // null log_io and every line from it loses its timestamp.
    if (!pre_reload) shared.log_io = self.io;
}

comptime {
    if (@import("builtin").output_mode == .Lib) _ = ffi;
}

pub const Table = struct {
    systemInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    systemDeinit: *const fn (*anyopaque) callconv(.c) void,
    systemUpdate: *const fn (*anyopaque, world: *World) callconv(.c) bool,
    systemReload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
};

pub const ffi = struct {
    pub export fn systemInit(data: *const Data) ?*anyopaque {
        std.log.info("system init", .{});
        const context = data.gpa.create(System) catch return null;
        context.init(data.*) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system init: {s}", .{@errorName(err)});
            data.gpa.destroy(context);
            return null;
        };
        return context;
    }

    pub export fn systemDeinit(handle: *anyopaque) void {
        std.log.info("system deinit", .{});
        const context: *System = @ptrCast(@alignCast(handle));
        const gpa = context.gpa;
        context.deinit();
        gpa.destroy(context);
    }

    pub export fn systemUpdate(handle: *anyopaque, world: *World) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const context: *System = @ptrCast(@alignCast(handle));
        context.update(world) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system update: {s}", .{@errorName(err)});
        };
        return context.request_exit;
    }

    pub export fn systemReload(handle: *anyopaque, pre_reload: bool) void {
        const context: *System = @ptrCast(@alignCast(handle));
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system reload: {s}", .{@errorName(err)});
        };
    }
};
