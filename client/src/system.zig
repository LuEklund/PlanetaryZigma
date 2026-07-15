const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const yes = @import("yes");
const NetworkManager = @import("system/NetworkManager.zig");
const AssetServer = @import("shared").AssetServer;
const Spawner = @import("system/Spawner.zig");
const Animation = @import("system/Animations.zig");
pub const Renderer = @import("Renderer.zig");

pub const Camera = @import("system/Camera.zig");
pub const Controller = @import("system/Controller.zig");
pub const Hud = @import("system/Hud.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
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
        self.request_exit = false;
        self.fullscreen_applied = false;
        self.cursor_mode_applied = .normal;
    }

    pub fn deinit(self: *Context) void {
        self.window.setCursorMode(self.desktop, .normal) catch {};
        self.renderer.deinit(self.gpa);
        self.network_manager.deinit();
    }

    pub fn isInGame(self: *const Context) bool {
        return self.network_manager.server_conn != 0 or self.network_manager.steam_client.server_conn != 0;
    }

    pub fn update(self: *Context, info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        // tracy.frameMark();
        if (!self.isInGame()) {
            info.world.pause_menu_open = false;
            if (info.world.options_menu_return_to_pause) {
                info.world.options_menu_open = false;
                info.world.options_menu_return_to_pause = false;
            }
        }
        info.world.controller.update();
        if (info.world.pause_menu_open or info.world.options_menu_open) info.world.controller.resetMouseDelta();

        const paused_for_input = info.world.pause_menu_open or info.world.options_menu_open;
        info.world.updateParticles(info.delta_time);
        try Hud.update(info, &self.network_manager, &self.renderer.inner.ui, &info.world.controller);
        self.request_exit = self.request_exit or info.world.request_quit;
        if (paused_for_input or info.world.pause_menu_open or info.world.options_menu_open) {
            info.world.controller.clearInput();
            info.world.controller.resetMouseDelta();
        }
        try self.applyOptions(info);
        try self.renderer.update(info);
        try self.asset_server.update();
        try self.network_manager.update(info);
        try Spawner.update(info, self);
        try self.animation.update(info, &self.renderer.inner.skeletons);

        const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
        for (info.world.entities.values()) |*entity| {
            const motion = entity.update_motion orelse continue;
            const motion_time = @as(f32, @floatFromInt(motion.tick)) * shared.tick_seconds;
            const age = server_time - motion_time;
            const target = motion.position + nz.vec.scale(motion.velocity, age);

            if (motion.tick != entity.smoothed_moiton_tick) {
                entity.position_error = entity.transform.position - target;
                entity.smoothed_moiton_tick = motion.tick;
            }

            const error_decay = std.math.pow(f32, 1e-5, info.delta_time);
            entity.position_error = nz.vec.scale(entity.position_error, error_decay);
            entity.transform.position = target + entity.position_error;

            const target_rotation = nz.Quat(f32).fromVec(motion.rotation);
            const rotation_decay = std.math.pow(f32, 1e-5, info.delta_time);
            entity.transform.rotation = entity.transform.rotation.slerp(target_rotation, 1.0 - rotation_decay);
        }

        if (!paused_for_input and !info.world.pause_menu_open and !info.world.options_menu_open) info.world.camera.update(info);
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
        if (event.* == .key) {
            const key = event.key;
            if (key.state == .released and key.sym == .escape and info.world.controller.suppress_escape_release) {
                info.world.controller.suppress_escape_release = false;
                return;
            }
            if (key.state == .released and key.sym == .escape and info.world.options_menu_open) {
                const return_to_pause = info.world.options_menu_return_to_pause and self.isInGame();
                info.world.options_menu_open = false;
                info.world.options_menu_return_to_pause = false;
                info.world.pause_menu_open = return_to_pause;
                info.world.controller.clearInput();
                info.world.controller.resetMouseDelta();
                return;
            }
            if (key.state == .released and key.sym == .escape and self.isInGame()) {
                if (info.world.options_menu_open) {
                    info.world.options_menu_open = false;
                    info.world.options_menu_return_to_pause = false;
                    info.world.pause_menu_open = true;
                } else if (info.world.pause_menu_open) {
                    info.world.pause_menu_open = false;
                } else {
                    info.world.pause_menu_open = true;
                }
                info.world.controller.clearInput();
                info.world.controller.resetMouseDelta();
                return;
            }
        }
        info.world.controller.eventUpdate(event);
    }

    fn applyOptions(self: *Context, info: *const Info) !void {
        info.world.camera.fov_rad = info.world.options.fov_rad;
        if (self.fullscreen_applied != info.world.options.fullscreen) {
            const mode: yes.Window.Mode = if (info.world.options.fullscreen) .fullscreen else .windowed;
            try self.window.setMode(self.desktop, mode);
            self.fullscreen_applied = info.world.options.fullscreen;
        }
        const wants_cursor_lock = self.isInGame() and !info.world.pause_menu_open and !info.world.options_menu_open and self.window.focused;
        const cursor_mode: yes.Window.Property.CursorMode = if (wants_cursor_lock) .locked else .normal;
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
