const System = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const NetworkManager = @import("system/NetworkManager.zig");
pub const AssetServer = @import("render").AssetServer;
const Presentation = @import("render").Presentation;
const motion = @import("system/motion.zig");
const extract = @import("system/extract.zig");
const FramePacket = @import("render").FramePacket;

const menu_world = @import("system/menu.zig");
const particle_lab = @import("system/particle_lab.zig");
pub const Options = @import("Options.zig");
pub const Backend = @import("render").Backend;

pub const Camera = @import("system/Camera.zig");
pub const Chat = @import("system/Chat.zig");
pub const Controller = @import("system/Controller.zig");
pub const Hud = @import("system/Hud.zig");
pub const Ui = @import("render").Ui;

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
steam_client: *shared.SteamNet.Client,
asset_server: *AssetServer,
render: shared.HotLib(Backend.Table, *anyopaque, "renderInit", "renderReload"),
render_handle: *anyopaque,
network_manager: NetworkManager,
presentation: Presentation,
frame_packet: FramePacket,
ui: Ui,
scene: Scene,
hud: Hud,
fonts: [Backend.FontLoader.count]@import("render").Font,
model_table: Backend.ModelTable,
texture_paths: std.StringHashMapUnmanaged(Backend.Image.Handle),
options: Options,
request_exit: bool = false,
fullscreen_applied: bool = false,
window_size_applied: Window.Size = .{},

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
    self.steam_client = data.steam_client;
    self.asset_server = data.asset_server;
    // Hot-reloadable, but only function bodies survive: adding a field to
    // Vulkan/Resources/Swapchain reinterprets live GPU state, so those edits need a restart.
    self.fonts = @splat(.empty);
    self.model_table = try .init(data.gpa);
    self.texture_paths = .empty;
    self.render = try .init("render", data.io);
    errdefer self.render.deinit(data.io);
    self.render_handle = self.render.symbols.renderInit(&Backend.Data{
        .gpa = data.gpa,
        .io = data.io,
        .asset_server = data.asset_server,
        .fonts = &self.fonts,
        .models = &self.model_table,
        .texture_paths = &self.texture_paths,
        .window = data.window,
    }) orelse return error.RenderInit;
    errdefer self.render.symbols.renderDeinit(self.render_handle);
    try self.network_manager.init(data.gpa, data.io, data.steam_client);
    errdefer self.network_manager.deinit();
    self.presentation = try .init(data.gpa);
    errdefer self.presentation.deinit();
    self.frame_packet = try .init(data.gpa);
    errdefer self.frame_packet.deinit(data.gpa);
    self.ui = try .init(data.gpa, data.window.size.width, data.window.size.height);
    errdefer self.ui.deinit(data.gpa);
    self.ui.default_font = &self.fonts[0];
    self.ui.handles_by_path = &self.texture_paths;
    self.options = .{};
    try self.enterScene(data.world, .menu);
    self.request_exit = false;
    self.fullscreen_applied = false;
    self.window_size_applied = data.window.size;
}

pub fn deinit(self: *System) void {
    self.network_manager.deinit();
    self.ui.deinit(self.gpa);
    self.frame_packet.deinit(self.gpa);
    self.presentation.deinit();
    self.render.symbols.renderDeinit(self.render_handle);
    self.render.deinit(self.io);
    self.model_table.deinit(self.gpa);
}

fn enterScene(self: *System, world: *World, next: Scene) !void {
    world.clearSession();
    self.presentation.clear();
    self.hud = .{};
    switch (next) {
        .menu => menu_world.populate(world),
        .game => {},
        .particle_lab => particle_lab.populate(world),
    }
    self.scene = next;
}

pub fn update(self: *System, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    // tracy.frameMark();
    var text_buffer: [64]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buffer);
    try self.window.poll(.{ .text = if (world.chat.open) &text_writer else null });
    try self.handleInput(world, text_buffer[0..text_writer.end]);
    const paused_before_hud = self.hud.overlay != .none;
    if (self.scene == .menu) menu_world.update(world, world.elapsed_time);
    if (self.scene == .particle_lab) particle_lab.update(world, &self.presentation);
    switch (try self.hud.update(world, self.scene, &self.network_manager, &self.ui, &world.controller, &self.options)) {
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
    for (world.entities.values()) |*entity| entity.stun_time = @max(0, entity.stun_time - world.delta_time);

    extract.extract(world, &self.ui, &self.frame_packet, self.scene != .particle_lab);
    try extract.present(world, &self.presentation, &self.model_table, &self.frame_packet);
    self.frame_packet.commands.appendSliceAssumeCapacity(world.render_outbox.items);
    world.render_outbox.clearRetainingCapacity();
    _ = self.render.symbols.renderUpdate(self.render_handle, &self.frame_packet);
    try self.render.swap(self.io, null, self.render_handle);
    try self.asset_server.reloadChangedAssets();

    const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
    motion.evaluate(world, server_time);

    if (!paused_before_hud and self.hud.overlay == .none) world.camera.update(world, &self.options);
    world.controller.resetMouseDelta();
    world.controller.mouse_wheel = 0;
    // std.log.debug("time : {d}", .{world.elapsed_time});
}

fn handleInput(self: *System, world: *World, typed: []const u8) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const window = self.window;
    if (!window.size.eql(self.window_size_applied)) {
        self.ui.screen_width = @floatFromInt(window.size.width);
        self.ui.screen_heigth = @floatFromInt(window.size.height);
        self.window_size_applied = window.size;
    }
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
    if (self.scene == .game) world.camera.fov_rad = self.options.fov_rad;
    world.chunk_view_distance = @intFromFloat(@max(1.0, @round(self.options.chunk_view_distance)));
    if (self.fullscreen_applied != self.options.fullscreen) {
        try self.window.setFullscreen(self.options.fullscreen);
        self.fullscreen_applied = self.options.fullscreen;
    }
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
