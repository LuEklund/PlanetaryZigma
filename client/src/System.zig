const System = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const Audio = @import("system/Audio.zig");
const NetworkManager = @import("system/NetworkManager.zig");
const Assets = @import("graphics").Assets;
const Animator = @import("graphics").Animator;
const Emitter = @import("graphics").Emitter;
const motion = @import("system/motion.zig");
const extract = @import("system/extract.zig");
const animate = @import("system/animate.zig");
const chunks = @import("system/chunks.zig");
const renderer_contract = @import("contract");
const DrawList = @import("contract").DrawList;

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
render: shared.HotLib(renderer_contract.Api, *anyopaque),
draw_list: DrawList,
audio: Audio,
assets: Assets,
animator: Animator,
emitters: Emitter.List,
network_manager: NetworkManager,
scene: Scene,
hud: Hud,
request_exit: bool,
teleport_sphere_model: u32,
hover_sound: u32,
click_sound: u32,
primary_sound: u32,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    world: *World,
    steam_client: *shared.SteamNet.Client,
};

pub fn init(self: *System, data: Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.window = data.window;

    try self.audio.init();

    self.animator = try .init(data.gpa);
    errdefer self.animator.deinit();
    self.emitters = @splat(Emitter.free);

    self.render = try .init("render", data.gpa, data.io);
    errdefer self.render.deinit(data.io);
    self.render.handle = self.render.api.init(&renderer_contract.InitOptions{
        .gpa = data.gpa,
        .io = data.io,
        .window = @ptrCast(data.window),
    }) orelse return error.RenderInit;
    errdefer self.render.api.deinit(self.render.handle);

    self.assets = try .init(data.gpa, data.io);
    self.teleport_sphere_model = try self.assets.models.add(data.gpa, "portalSphere.glb", null);
    errdefer self.assets.deinit(data.gpa, data.io);

    var sound_path_buffer: [128]u8 = undefined;
    self.hover_sound = try self.audio.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/button-hover.mp3", .{self.assets.root}));
    self.click_sound = try self.audio.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/button-click.mp3", .{self.assets.root}));
    self.primary_sound = try self.audio.addSound(try std.fmt.bufPrintZ(&sound_path_buffer, "{s}/sounds/laser-gun.mp3", .{self.assets.root}));

    self.draw_list = try .init(data.gpa);
    errdefer self.draw_list.deinit(data.gpa);

    try self.assets.update(data.gpa, data.io, &self.render);

    try self.hud.init(data.gpa, data.window.size);
    errdefer self.hud.deinit(data.gpa);
    try self.network_manager.init(data.gpa, data.io, data.steam_client);
    errdefer self.network_manager.deinit();
    try self.enterScene(data.world, .menu);
    self.request_exit = false;
}

pub fn deinit(self: *System) void {
    self.network_manager.deinit();
    self.audio.deinit();
    self.hud.deinit(self.gpa);
    self.draw_list.deinit(self.gpa);
    self.animator.deinit();
    self.assets.deinit(self.gpa, self.io);
    self.render.api.deinit(self.render.handle);
    self.render.deinit(self.io);
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
    switch (try self.hud.update(world, self.scene, &self.network_manager, &world.options, &self.assets)) {
        .none => {},
        .main_menu => try self.network_manager.returnToMainMenu(),
        .quit => self.request_exit = true,
    }
    switch (self.hud.ui.play_sound) {
        .hot => try self.audio.playSound(self.hover_sound),
        .clicked => try self.audio.playSound(self.click_sound),
        .none => {},
    }
    // std.log.debug("hot: {any}", .{self.hud.ui.last_hot_item});
    // std.log.debug("active: {any}", .{self.hud.ui.last_active_item});
    // std.log.debug("playsound: {t}", .{self.hud.ui.play_sound});
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
    chunks.update(&world.planet, &self.render.api, self.render.handle);
    try animate.update(world, &self.animator, &self.assets.models);

    for (world.action_events.items) |action| {
        switch (action.action) {
            .primary => try self.audio.playSound(self.primary_sound),
            else => {},
        }
    }
    world.action_events.clearRetainingCapacity();

    try extract.frame(self, world, self.scene != .particle_lab);
    self.render.trySwap(self.io);
    self.assets.update(self.gpa, self.io, &self.render) catch |err| std.log.err("assets: {t}", .{err});

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

pub const Api = struct {
    systemInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    systemDeinit: *const fn (*anyopaque) callconv(.c) void,
    systemUpdate: *const fn (*anyopaque, world: *World) callconv(.c) bool,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
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

    pub export fn reload(handle: *anyopaque, pre_reload: bool) void {
        const context: *System = @ptrCast(@alignCast(handle));
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system reload: {s}", .{@errorName(err)});
        };
    }
};
