const System = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const Audio = @import("system/Audio.zig");
const Settings = @import("Settings.zig");
const Discord = @import("system/Discord.zig");
const Network = @import("system/Network.zig");
const Assets = @import("graphics").Assets;
const Animator = @import("graphics").Animator;
const Particle = @import("graphics").Particle;
const motion = @import("system/motion.zig");
const extract = @import("system/extract.zig");
const animate = @import("system/animate.zig");
const chunks = @import("system/chunks.zig");
const events = @import("system/events.zig");
const renderer_contract = @import("renderer_contract");
const DrawList = renderer_contract.DrawList;

const menu_world = @import("system/menu.zig");
const zoo_scene = @import("system/zoo.zig");
const zoo_hud = @import("system/hud/zoo.zig");

pub const Chat = @import("system/Chat.zig");
const Hud = @import("system/Hud.zig");
const dvui = @import("dvui");
const DvuiBackend = @import("dvui_backend");
const DvuiInput = @import("dvui_input");

pub const std_options: std.Options = .{ .logFn = shared.logFn };

pub const Scene = enum {
    menu,
    game,
    zoo,
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
particles: Particle,
network: Network,
scene: Scene,
zoo: zoo_scene.State,
hud: Hud,
dvui_backend: DvuiBackend,
dvui_window: dvui.Window,
dvui_input: DvuiInput,
request_exit: bool,
auto_ready: bool,
console_path: ?[]const u8,
console_next_poll: f32,
world: World,
clock: shared.Clock,
fps_window_start: std.Io.Timestamp,
fps_window_steps: u32,

teleport_sphere_model: u32,
skill_sounds: std.EnumArray(shared.entity.Skill, Audio.Sound),

pub const Init = @import("system_contract.zig").Init;

pub fn init(self: *System, data: Init) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.window = data.window;
    self.world = try .init(data.gpa);
    errdefer self.world.deinit(data.gpa);
    const settings: Settings = .load(data.io, data.gpa);
    self.world.options = settings.options;
    self.world.controller.bindings = settings.bindings;
    self.clock = .init(data.io);
    self.fps_window_start = self.clock.previous;
    self.fps_window_steps = 0;

    self.discord = if (data.discord_dir) |discord_dir| .{
        .socket = null,
        .dir = discord_dir,
        .last = null,
        .next_send_time = 0,
        .nonce = 0,
    } else null;

    self.animator = try .init(data.gpa);
    errdefer self.animator.deinit();
    self.particles.clear();

    self.render = try .init("render", data.gpa, data.io);
    errdefer self.render.deinit(data.io);
    self.render.handle = self.render.api.init(&renderer_contract.InitOptions{
        .gpa = data.gpa,
        .io = data.io,
        .window = @ptrCast(data.window),
    }) orelse return error.RenderInit;
    errdefer self.render.api.deinit(self.render.handle);

    self.assets = try .init(data.gpa, data.io);
    self.teleport_sphere_model = try self.assets.models.add(data.gpa, "objects/portalsphere.glb", null);
    errdefer self.assets.deinit(data.gpa, data.io);

    try self.audio.init(self.assets.root);
    const laser_sound: Audio.Sound = try self.audio.load("laser-gun.mp3", .{});
    self.skill_sounds = .initFill(.none);
    self.skill_sounds.set(.melee, try self.audio.load("punch.mp3", .{}));
    self.skill_sounds.set(.shoot, laser_sound);
    self.skill_sounds.set(.shoot_cube, laser_sound);

    self.draw_list = try .init(data.gpa);
    errdefer self.draw_list.deinit(data.gpa);

    try self.assets.update(data.gpa, data.io, &self.render);

    self.hud = .init;
    self.dvui_backend = .{
        .io = data.io,
        .size = .{
            .w = @floatFromInt(data.window.size.width),
            .h = @floatFromInt(data.window.size.height),
        },
        .scale = 1,
        .text_input_wanted = false,
        .frame = null,
    };
    self.dvui_input = .{ .buttons = .{}, .position = .{ .x = 0, .y = 0 } };
    self.dvui_window = try .init(
        @src(),
        data.gpa,
        self.dvui_backend.backend(),
        .{ .color_scheme = .dark, .keybinds = .none },
    );
    errdefer self.dvui_window.deinit();
    try self.network.init(data.gpa, data.io, data.log_connection_status);
    errdefer self.network.deinit();
    self.zoo = .{};
    try self.enterScene(&self.world, .menu);
    self.auto_ready = false;
    self.console_path = data.console;
    self.console_next_poll = 0;
    if (data.autostart) |autostart| {
        if (std.mem.eql(u8, autostart, "run")) {
            self.network.requestHost(.singleplayer, true);
            self.auto_ready = true;
        } else if (std.mem.eql(u8, autostart, "singleplayer")) {
            self.network.requestHost(.singleplayer, false);
        } else if (std.mem.eql(u8, autostart, "dev")) {
            self.network.requestHost(.singleplayer, true);
        } else if (std.mem.eql(u8, autostart, "zoo")) {
            try self.enterScene(&self.world, .zoo);
        } else std.log.err(
            "PZ_AUTOSTART: unknown \"{s}\", expected singleplayer, dev, run or zoo",
            .{autostart},
        );
    }
    self.request_exit = false;
}

pub fn deinit(self: *System) void {
    self.network.deinit();
    self.audio.deinit();
    if (self.discord) |*discord| if (discord.socket) |socket| socket.close(self.io);
    self.dvui_window.deinit();
    self.draw_list.deinit(self.gpa);
    self.animator.deinit();
    self.assets.deinit(self.gpa, self.io);
    self.render.api.deinit(self.render.handle);
    self.render.deinit(self.io);
    self.world.deinit(self.gpa);
}

fn enterScene(self: *System, world: *World, next: Scene) !void {
    world.clear();
    self.animator.clear();
    self.particles.clear();
    self.hud.resetScreen();
    switch (next) {
        .menu => try menu_world.populate(world, self.gpa),
        .game => {},
        .zoo => try zoo_scene.populate(world, self.gpa, &self.zoo),
    }
    self.scene = next;
}

pub fn update(self: *System) !void {
    if (!self.clock.stepDue(self.io, shared.tick_seconds)) return;
    const world = &self.world;
    world.elapsed_time += shared.tick_seconds;
    world.delta_time = shared.tick_seconds;
    self.fps_window_steps += 1;
    const now: std.Io.Timestamp = .now(self.io, .awake);
    const fps_window_seconds = @as(
        f32,
        @floatFromInt(self.fps_window_start.durationTo(now).nanoseconds),
    ) / std.time.ns_per_s;
    if (fps_window_seconds >= 0.5) {
        world.fps = @as(f32, @floatFromInt(self.fps_window_steps)) / fps_window_seconds;
        self.fps_window_steps = 0;
        self.fps_window_start = now;
    }
    try self.step(world);
    tracy.frameMark();
}

fn step(self: *System, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    world.planet.clearOutboxes();
    const options_were_open = self.hud.overlay == .options;
    defer if (options_were_open and self.hud.overlay != .options) Settings.save(self.io, .{
        .options = world.options,
        .bindings = world.controller.bindings,
    });
    var text_buffer: [1024]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buffer);
    try self.window.poll(.{ .text = if (world.chat.open) &text_writer else null });
    switch (self.scene) {
        .menu => menu_world.update(world),
        .zoo => zoo_scene.update(world, &self.zoo, self.window.pointer.axis.vertical),
        .game => {},
    }
    self.dvui_backend.size = .{
        .w = @floatFromInt(self.window.size.width),
        .h = @floatFromInt(self.window.size.height),
    };
    self.dvui_backend.scale = std.math.clamp(self.dvui_backend.size.h / 1080, 0.5, 3);
    self.dvui_backend.frame = .{
        .draw_list = &self.draw_list,
        .render_api = &self.render.api,
        .render_handle = self.render.handle,
    };
    self.dvui_window.backend = self.dvui_backend.backend();
    try self.dvui_input.push(&self.dvui_window, self.window, "", &.{});
    try self.dvui_window.begin(self.dvui_backend.nanoTime());
    const hud_request = try self.hud.update(
        world,
        self.scene,
        &self.network,
        &world.options,
        &self.assets,
    );
    const zoo_command: zoo_scene.Command = if (self.scene == .zoo) zoo_hud.update(&self.zoo, &self.assets.models) else .none;
    _ = try self.dvui_window.end(.{});
    try self.applyZooCommand(world, zoo_command);
    if (self.auto_ready and world.stage == 0) if (world.getPtr(world.player_id)) |player| {
        if (!player.ready) try self.network.sendCommand(.{ .lobby = .{ .ready = true } }, .reliable);
        self.auto_ready = false;
    };
    try self.pollConsole(world);
    switch (hud_request) {
        .none => {},
        .main_menu => try self.network.returnToMainMenu(),
        .lobby => |lobby_command| try self.network.sendCommand(
            .{ .lobby = lobby_command },
            .reliable,
        ),
        .quit => self.request_exit = true,
        .zoo => try self.enterScene(world, .zoo),
    }

    const player_input: shared.net.Input = try self.handleInput(
        world,
        text_buffer[0..text_writer.end],
    );
    const wire_input: shared.net.Input = if (world.controller.free_camera) .{} else player_input;
    try self.network.update(
        wire_input,
        world.options.survivor,
        world.elapsed_time,
        world.delta_time,
    );
    if (world.go_again_pending) {
        try self.network.sendCommand(.go_again, .reliable);
        world.go_again_pending = false;
    }
    if (world.chat.pending) {
        const chat_text = world.chat.text();
        try self.network.sendCommand(
            .{ .chat = .{ .text_len = @intCast(chat_text.len), .text = chat_text } },
            .reliable,
        );
        world.chat.pending = false;
        world.chat.input_len = 0;
    }

    const next_scene: Scene = if (self.network.connected()) .game else if (self.scene == .zoo) .zoo else .menu;
    if (next_scene != self.scene) try self.enterScene(world, next_scene);
    if (self.discord) |*discord| discord.update(
        self.io,
        .{ .scene = self.scene },
        world.elapsed_time,
    );
    try world.update(self.gpa, self.network.packets.items);
    for (world.entities.values()) |*entity| {
        entity.stun_time = @max(0, entity.stun_time - world.delta_time);
    }
    events.apply(
        world,
        self.network.packets.items,
        &self.audio,
        &self.skill_sounds,
        &self.particles,
    );

    try world.planet.update(
        self.gpa,
        &.{
            if (world.getPtr(
                world.player_id,
            )) |player| player.transform.position else world.camera.transform.position,
        },
        @intFromFloat(@max(1.0, @round(world.options.chunk_view_distance))),
    );
    chunks.update(&world.planet, &self.render.api, self.render.handle);
    try animate.update(world, &self.animator, &self.assets.models, self.network.packets.items);
    self.audio.update();

    try extract.frame(self, world, true);
    self.render.trySwap(self.io);
    self.assets.update(
        self.gpa,
        self.io,
        &self.render,
    ) catch |err| std.log.err("assets: {t}", .{err});

    const server_time = self.network.server_tick_estimate * shared.tick_seconds;
    motion.evaluate(world, server_time);

    try self.applyOptions(world);
    const look_delta: @Vector(2, f64) = switch (self.window.pointer.movement) {
        .relative => |relative| if (world.chat.open) .{ 0, 0 } else .{ relative.dx, relative.dy },
        .position => .{ 0, 0 },
    };
    if (self.hud.overlay == .none) world.camera.update(
        world,
        &world.options,
        look_delta,
        player_input,
        self.window.pointer.axis.vertical,
    );
}

/// Sends every line of the dev console file as a chat line (zoo: a zoo command), then empties the file.
fn pollConsole(self: *System, world: *World) !void {
    const path = self.console_path orelse return;
    if (world.elapsed_time < self.console_next_poll) return;
    self.console_next_poll = world.elapsed_time + 0.25;
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(self.io, path, self.gpa, .limited(16 * 1024)) catch return;
    defer self.gpa.free(content);
    if (content.len == 0) return;
    cwd.writeFile(self.io, .{ .sub_path = path, .data = "" }) catch {};
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        if (self.scene == .zoo) {
            try self.applyZooCommand(world, zoo_scene.parseCommand(line, &self.assets.models, &self.zoo));
            continue;
        }
        const text = line[0..@min(line.len, shared.max_chat_len)];
        try self.network.sendCommand(.{ .chat = .{ .text_len = @intCast(text.len), .text = text } }, .reliable);
    }
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
                    if (world.stage != 0) player_input = world.controller.update(self.window);
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
        .zoo => if (self.window.keyboard.get(.escape) == .press) try self.enterScene(world, .menu),
        .menu => if (self.hud.overlay == .options and world.controller.rebinding_action != null) {
            world.controller.captureBinding(self.window);
        } else if (self.window.keyboard.get(.escape) == .press) {
            if (self.hud.overlay == .options) {
                self.hud.overlay = .none;
            } else {
                self.request_exit = true;
            }
        },
    }
    player_input.camera_position = world.camera.transform.position;
    player_input.camera_rotation = world.camera.transform.rotation.toVec();
    return player_input;
}

fn applyZooCommand(self: *System, world: *World, command: zoo_scene.Command) !void {
    const kind = zoo_scene.kinds[self.zoo.kind_index];
    switch (command) {
        .none => {},
        .exit => try self.enterScene(world, .menu),
        .select_kind => |index| {
            self.zoo.kind_index = index;
            try self.enterScene(world, .zoo);
        },
        .select_slot => |slot| {
            self.zoo.slot = slot;
            if (slot == .action) self.playZooAction(world);
        },
        .assign_clip => |clip| zoo_scene.assign(self.io, &self.assets.models, kind, self.zoo.slot, clip) catch |err|
            std.log.err("zoo: save manifest: {t}", .{err}),
        .play_action => self.playZooAction(world),
    }
}

fn playZooAction(self: *System, world: *World) void {
    const action = switch (self.zoo.slot) {
        .action => |action| action,
        .loop => return,
    };
    const models = &self.assets.models;
    const clip = models.rig(models.get(zoo_scene.kinds[self.zoo.kind_index])).action_clips.get(action) orelse return;
    self.animator.playOverlay(zoo_scene.subjectAnimation(world), clip, models);
}

fn applyOptions(self: *System, world: *World) !void {
    try self.window.setFullscreen(world.options.fullscreen);
    self.audio.setVolume(world.options.master_volume);
    const wants_cursor_lock = self.scene == .game and world.stage != 0 and self.hud.overlay == .none and self.window.focused;
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
    _ = ffi;
}

pub const Api = @import("system_contract.zig").Api;

const layout_hash = shared.layout.hash(&.{ System, World });

pub const ffi = struct {
    pub export fn layoutHash() u64 {
        return layout_hash;
    }

    pub export fn systemInit(data: *const Init) ?*anyopaque {
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

    pub export fn systemUpdate(handle: *anyopaque) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const context: *System = @ptrCast(@alignCast(handle));
        context.update() catch |err| {
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
