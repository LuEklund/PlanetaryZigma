const System = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const Audio = @import("system/Audio.zig");
const Discord = @import("system/Discord.zig");
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
discord: ?Discord,
assets: Assets,
animator: Animator,
emitters: Emitter.List,
network_manager: NetworkManager,
scene: Scene,
hud: Hud,
request_exit: bool,

teleport_sphere_model: u32,
button_hover_sound: Audio.Sound,
button_click_sound: Audio.Sound,
melee_sound: Audio.Sound,
shoot_cube_sound: Audio.Sound,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    world: *World,
    log_connection_status: bool,
    discord_dir: ?[]const u8,
};

pub fn init(self: *System, data: Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.window = data.window;

    self.discord = if (data.discord_dir) |discord_dir| .{
        .socket = null,
        .dir = discord_dir,
        .last = null,
        .next_send_time = 0,
        .nonce = 0,
    } else null;

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
    self.teleport_sphere_model = try self.assets.models.add(data.gpa, "portalsphere.glb", null);
    errdefer self.assets.deinit(data.gpa, data.io);

    try self.audio.init(self.assets.root);
    self.button_hover_sound = try self.audio.load("button-hover.mp3", .{});
    self.button_click_sound = try self.audio.load("button-click.mp3", .{});
    self.melee_sound = try self.audio.load("punch.mp3", .{});
    self.shoot_cube_sound = try self.audio.load("laser-gun.mp3", .{});

    self.draw_list = try .init(data.gpa);
    errdefer self.draw_list.deinit(data.gpa);

    try self.assets.update(data.gpa, data.io, &self.render);

    try self.hud.init(data.gpa, data.window.size);
    errdefer self.hud.deinit(data.gpa);
    try self.network_manager.init(data.gpa, data.io, data.log_connection_status);
    errdefer self.network_manager.deinit();
    try self.enterScene(data.world, .menu);
    self.request_exit = false;
}

pub fn deinit(self: *System) void {
    self.network_manager.deinit();
    self.audio.deinit();
    if (self.discord) |*discord| if (discord.socket) |socket| socket.close(self.io);
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
    if (self.scene == .menu) menu_world.update(world);
    if (self.scene == .particle_lab) particle_lab.update(&self.emitters, world.elapsed_time);
    switch (try self.hud.update(world, self.scene, self.window, &self.network_manager, &world.options, &self.assets)) {
        .none => {},
        .main_menu => try self.network_manager.returnToMainMenu(),
        .quit => self.request_exit = true,
    }

    var player_input: shared.net.Input = try self.handleInput(world, text_buffer[0..text_writer.end]);
    player_input.camera_position = world.camera.transform.position;
    player_input.camera_rotation = world.camera.transform.rotation.toVec();
    try self.network_manager.update(world, player_input);

    switch (self.hud.ui.play_sound) {
        .hot => self.audio.play(self.button_hover_sound),
        .clicked => self.audio.play(self.button_click_sound),
        .none => {},
    }
    const next_scene: Scene = if (self.network_manager.connected()) .game else .menu;
    if (self.scene != .particle_lab and next_scene != self.scene) try self.enterScene(world, next_scene);
    if (self.discord) |*discord| discord.update(self.io, .{ .scene = self.scene }, world.elapsed_time);
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

    for (world.action_events.items) |action_event| {
        const entity = world.getPtr(action_event.id) orelse continue;
        const assigned_skill = entity.kind.spec().skills.get(action_event.action) orelse continue;
        std.log.debug("kind {t}, action {t}", .{
            entity.kind,
            assigned_skill.skill,
        });
        const sound: Audio.Sound = switch (assigned_skill.skill) {
            .melee => self.melee_sound,
            .shoot_cube, .shoot => self.shoot_cube_sound,
            else => continue,
        };
        self.audio.play(sound);
        // if (self.assets.models.rig(self.assets.models.get(entity.kind)).action_clips.get(action_event.action)) |clip|
        // switch (action.action) {
        //     .primary => try self.audio.playSound(self.primary_sound),
        //     else => {},
        // }
    }
    world.action_events.clearRetainingCapacity();
    self.audio.update();

    try extract.frame(self, world, self.scene != .particle_lab);
    self.render.trySwap(self.io);
    self.assets.update(self.gpa, self.io, &self.render) catch |err| std.log.err("assets: {t}", .{err});

    const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
    motion.evaluate(world, server_time);

    try self.applyOptions(world);
    const look_delta: @Vector(2, f64) = switch (self.window.pointer.movement) {
        .relative => |relative| if (world.chat.open) .{ 0, 0 } else .{ relative.dx, relative.dy },
        .position => .{ 0, 0 },
    };
    if (self.hud.overlay == .none) world.camera.update(world, &world.options, look_delta, player_input, self.window.pointer.axis.vertical);
}

fn handleInput(self: *System, world: *World, typed: []const u8) !shared.net.Input {
    var player_input: shared.net.Input = .{};
    switch (self.scene) {
        .game => switch (self.hud.overlay) {
            .none => {
                if (world.chat.open) {
                    world.chat.handleText(typed);
                    world.chat.handleKeyboard(self.window.keyboard);
                } else {
                    if (self.window.keyboard.get(Chat.open_key) == .press) world.chat.open = true;
                    if (self.window.keyboard.get(.escape) == .press) self.hud.overlay = .pause;
                    player_input = world.controller.update(self.window);
                }
            },
            .pause => if (self.window.keyboard.get(.escape) == .press) {
                self.hud.overlay = .none;
            },
            .options => if (world.controller.rebinding_action != null) {
                world.controller.captureBinding(self.window);
            } else if (self.window.keyboard.get(.escape) == .press) {
                self.hud.overlay = if (self.hud.overlay.options.return_to_pause) .pause else .none;
            },
            .wipe => {
                world.chat.open = false;
                world.chat.input_len = 0;
            },
        },
        .menu => if (self.hud.overlay == .options and world.controller.rebinding_action != null) {
            world.controller.captureBinding(self.window);
        } else if (self.window.keyboard.get(.escape) == .press) {
            if (self.hud.overlay == .options) {
                self.hud.overlay = .none;
            } else {
                self.request_exit = true;
            }
        },
        .particle_lab => if (self.window.keyboard.get(.escape) == .press) try self.enterScene(world, .menu),
    }
    return player_input;
}

// if (self.window.keyboard.get(.f4) == .release and self.scene == .menu) {
//     try self.enterScene(world, .particle_lab);
//     return;
// }

fn applyOptions(self: *System, world: *World) !void {
    try self.window.setFullscreen(world.options.fullscreen);
    const wants_cursor_lock = self.scene == .game and self.hud.overlay == .none and self.window.focused;
    if (wants_cursor_lock) {
        try self.window.setPointerVisible(false);
        try self.window.setPointerConstraint(.locked);
        try self.window.setPointerRelative(true);
    } else {
        try self.window.setPointerRelative(false);
        try self.window.setPointerConstraint(.none);
        try self.window.setPointerVisible(true);
    }
}

fn reload(self: *System, pre_reload: bool) !void {
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
