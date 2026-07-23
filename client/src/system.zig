const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const yes = @import("yes");
const NetworkManager = @import("system/NetworkManager.zig");
pub const AssetServer = @import("AssetServer.zig");
const Animation = @import("system/Animations.zig");
const AnimationInstance = @import("asset/AnimationInstance.zig");
const motion = @import("system/motion.zig");
const Emitter = @import("system/Emitter.zig");
const menu_world = @import("system/menu.zig");
pub const Options = @import("Options.zig");
pub const Renderer = @import("Renderer.zig");

pub const Camera = @import("system/Camera.zig");
pub const Chat = @import("system/Chat.zig");
pub const Controller = @import("system/Controller.zig");
pub const Hud = @import("system/Hud.zig");
pub const Ui = @import("Ui.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Scene = enum {
    menu,
    game,
};

pub const World = @import("World.zig");
pub const Entity = World.Entity;

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    desktop: yes.Desktop,
    window: *yes.Window,
    steam_client: *shared.SteamNet.Client,
    asset_server: *AssetServer,
    renderer: Renderer,
    network_manager: NetworkManager,
    animation: Animation,
    animation_instances: std.AutoHashMap(shared.entity.Id, AnimationInstance),
    ui: Ui,
    scene: Scene,
    hud: Hud,
    options: Options,
    request_exit: bool = false,
    fullscreen_applied: bool = false,
    cursor_mode_applied: yes.Window.Property.CursorMode = .normal,

    pub const Data = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        desktop: yes.Desktop,
        window: *yes.Window,
        asset_server: *AssetServer,
        world: *World,
        steam_client: *shared.SteamNet.Client,
    };

    pub fn init(self: *Context, data: Data) !void {
        self.gpa = data.gpa;
        self.io = data.io;
        self.desktop = data.desktop;
        self.window = data.window;
        self.steam_client = data.steam_client;
        self.asset_server = data.asset_server;
        self.renderer = try .init(data.gpa, data.asset_server, data.desktop, data.window);
        try self.network_manager.init(data.gpa, data.io, data.steam_client);
        self.animation = .init(data.gpa);
        self.animation_instances = .init(data.gpa);
        self.ui = try .init(data.gpa, data.window.size.width, data.window.size.height);
        self.ui.default_font = &self.renderer.inner.resources.font_loader.items[0];
        self.options = .{};
        try self.enterScene(data.world, .menu);
        self.request_exit = false;
        self.fullscreen_applied = false;
        self.cursor_mode_applied = .normal;
    }

    pub fn deinit(self: *Context) void {
        self.window.setCursorMode(self.desktop, .normal) catch {};
        var instance_iterator = self.animation_instances.valueIterator();
        while (instance_iterator.next()) |instance| instance.deinit(self.gpa);
        self.animation_instances.deinit();
        self.ui.deinit(self.gpa);
        self.renderer.deinit(self.gpa);
        self.network_manager.deinit();
    }

    fn enterScene(self: *Context, world: *World, next: Scene) !void {
        world.clearSession();
        self.hud = .{};
        switch (next) {
            .menu => try menu_world.populate(world),
            .game => {},
        }
        self.scene = next;
    }

    pub fn update(self: *Context, info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        // tracy.frameMark();
        const paused_before_hud = self.hud.overlay != .none;
        Emitter.update(&info.world.emitters, info.elapsed_time);
        if (self.scene == .menu) menu_world.update(info.world, info.elapsed_time);
        switch (try self.hud.update(info, self.scene, &self.network_manager, &self.ui, &self.renderer.inner.resources.texture_table, &info.world.controller, &self.options)) {
            .none => {},
            .main_menu => try self.network_manager.returnToMainMenu(),
            .quit => self.request_exit = true,
        }
        if (paused_before_hud or self.hud.overlay != .none or info.world.chat.open) {
            info.world.controller.clearInput();
        }
        try self.applyOptions(info);
        try self.renderer.update(info, &self.animation_instances, &self.ui);
        try self.asset_server.reloadChangedAssets();
        try self.network_manager.update(info);
        const next_scene: Scene = if (self.network_manager.connected()) .game else .menu;
        if (next_scene != self.scene) try self.enterScene(info.world, next_scene);
        try info.world.flush(info.delta_time, &self.animation_instances);
        try self.renderer.inner.drainRenderCommands(self.gpa, &self.animation_instances, info.world);
        try self.animation.updateStates(info, &self.animation_instances);
        try self.animation.update(info, &self.animation_instances);

        const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
        motion.evaluate(info, server_time);

        if (!paused_before_hud and self.hud.overlay == .none) info.world.camera.update(info, &self.options);
        info.world.controller.resetMouseDelta();
        info.world.controller.mouse_wheel = 0;
        // std.log.debug("time : {d}", .{info.elapsed_time});
    }

    pub fn eventUpdate(self: *Context, info: *const Info, event: *const yes.Window.Event) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        if (info.world.controller.rebinding_action != null and (event.* == .key or event.* == .mouse_button)) {
            info.world.controller.eventUpdate(event);
            return;
        }
        if (event.* == .key and self.scene == .game and self.hud.overlay == .none) {
            const key = event.key;
            if (info.world.chat.open) {
                info.world.chat.handleKey(key);
                if (key.sym == .escape and key.state == .pressed) info.world.controller.suppress_escape_release = true;
                return;
            }
            if (key.state == .pressed and key.sym == Chat.open_key) {
                info.world.chat.open = true;
                info.world.controller.clearInput();
                return;
            }
        }
        if (event.* == .key) {
            const key = event.key;
            if (key.state == .released and key.sym == .escape and info.world.controller.suppress_escape_release) {
                info.world.controller.suppress_escape_release = false;
                return;
            }
            if (key.state == .released and key.sym == .escape and self.hud.overlay == .options) {
                self.hud.overlay = if (self.hud.overlay.options.return_to_pause and self.scene == .game) .pause else .none;
                info.world.controller.clearInput();
                info.world.controller.resetMouseDelta();
                return;
            }
            if (key.state == .released and key.sym == .escape and self.scene == .game) {
                self.hud.overlay = if (self.hud.overlay == .pause) .none else .pause;
                info.world.controller.clearInput();
                info.world.controller.resetMouseDelta();
                return;
            }
        }
        info.world.controller.eventUpdate(event);
    }

    fn applyOptions(self: *Context, info: *const Info) !void {
        if (self.scene == .game) info.world.camera.fov_rad = self.options.fov_rad;
        info.world.chunk_view_distance = @intFromFloat(@max(1.0, @round(self.options.chunk_view_distance)));
        if (self.fullscreen_applied != self.options.fullscreen) {
            const mode: yes.Window.Mode = if (self.options.fullscreen) .fullscreen else .windowed;
            try self.window.setMode(self.desktop, mode);
            self.fullscreen_applied = self.options.fullscreen;
        }
        const wants_cursor_lock = self.scene == .game and self.hud.overlay == .none and self.window.focused;
        const cursor_mode: yes.Window.Property.CursorMode = if (wants_cursor_lock) .captured else .normal;
        if (self.cursor_mode_applied != cursor_mode) {
            try self.window.setCursorMode(self.desktop, cursor_mode);
            self.cursor_mode_applied = cursor_mode;
            info.world.controller.resetMouseDelta();
        }
    }

    fn reload(self: *Context, pre_reload: bool) !void {
        if (pre_reload) {
            std.log.debug("pre-hotreload", .{});
        } else {
            std.log.debug("post-hotreload", .{});
            self.renderer.inner.rebindProcs();
        }
    }
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemContextInit: *const fn (*Context, data: *const Context.Data) callconv(.c) void,
        systemContextDeinit: *const fn (*Context) callconv(.c) void,
        systemContextUpdate: *const fn (*Context, data: *const Info, event: ?*const yes.Window.Event) callconv(.c) void,
        systemContextReload: *const fn (*Context, pre_reload: bool) callconv(.c) void,

        pub fn load(dynlib: *shared.DynLib) !Table {
            var self: Table = undefined;
            inline for (std.meta.fields(Table)) |field| {
                std.log.debug("Looking up symbol: {s}", .{field.name});
                const ptr = dynlib.lookup(field.type, field.name) orelse {
                    std.log.err("Failed to lookup symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                };
                @field(self, field.name) = ptr;
            }
            return self;
        }
    };

    pub export fn systemContextInit(context: *Context, data: *const Context.Data) void {
        std.log.debug("system context init", .{});
        context.init(data.*) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.debug.panic("context init: {s}", .{@errorName(err)});
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        std.log.debug("system context deinit", .{});
        context.deinit();
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info, event: ?*const yes.Window.Event) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = if (event != null) context.eventUpdate(info, event.?) else context.update(info);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.debug.panic("context update: {s}", .{@errorName(err)});
        };
    }

    pub export fn systemContextReload(context: *Context, pre_reload: bool) void {
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.debug.panic("context reload: {s}", .{@errorName(err)});
        };
    }
};
