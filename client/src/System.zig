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
const ping = @import("system/ping.zig");
const Controller = @import("system/Controller.zig");
const dump = @import("system/dump.zig");
const catalog = @import("system/catalog.zig");

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
steam_input: shared.SteamInput,
pad: shared.SteamInput.Frame,
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
    self.teleport_sphere_model = try self.assets.models.add(
        data.gpa,
        "objects/portalsphere.glb",
        null,
    );
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
    self.pad = .{};
    self.steam_input = startSteamInput(data.io, data.gpa);
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
    self.pad = self.steam_input.poll(&Controller.pad_names);
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
        .zoo => zoo_scene.update(world, &self.zoo),
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
    const zoo_command: zoo_scene.Command = if (self.scene == .zoo) zoo_hud.update(
        &self.zoo,
        &self.assets.models,
        world,
    ) else .none;
    _ = try self.dvui_window.end(.{});
    try self.applyZooCommand(world, zoo_command);
    if (self.auto_ready and world.stage == 0) if (world.getPtr(world.player_id)) |player| {
        if (!player.ready) try self.network.sendCommand(
            .{ .lobby = .{ .ready = true } },
            .reliable,
        );
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
    if (world.controller.ping_requested) {
        world.controller.ping_requested = false;
        try self.network.sendCommand(.{ .ping = ping.aim(world) }, .reliable);
    }
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

    const offline_scene: Scene = if (self.scene == .zoo) .zoo else .menu;
    const next_scene: Scene = if (self.network.connected()) .game else offline_scene;
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
    const mouse_delta: @Vector(2, f64) = switch (self.window.pointer.movement) {
        .relative => |relative| .{ relative.dx, relative.dy },
        .position => .{ 0, 0 },
    };
    const pad_delta: @Vector(2, f64) = .{ self.pad.look[0], self.pad.look[1] };
    const look_delta: @Vector(2, f64) = if (world.chat.open) .{ 0, 0 } else mouse_delta + pad_delta;
    if (self.hud.overlay == .none) world.camera.update(
        world,
        &world.options,
        look_delta,
        player_input,
        self.window.pointer.axis.vertical,
    );
}

/// Runs every line of the dev console file, then empties it:
/// `!dump` (state to `<console>.state`), `!ping`, a zoo command in the zoo, else a chat line.
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
        if (std.mem.eql(u8, line, "!catalog")) {
            self.writeCatalog(path);
            continue;
        }
        if (std.mem.eql(u8, line, "!dump")) {
            self.writeStateDump(world, path);
            continue;
        }
        if (std.mem.startsWith(u8, line, "!fx ")) {
            self.spawnEffectInView(world, line["!fx ".len..]);
            continue;
        }
        if (std.mem.eql(u8, line, "!cave")) {
            flyIntoCave(world);
            continue;
        }
        if (std.mem.eql(u8, line, "!ping")) {
            world.controller.ping_requested = true;
            continue;
        }
        if (self.scene == .zoo) {
            try self.applyZooCommand(
                world,
                zoo_scene.parseCommand(line, &self.assets.models, &self.zoo),
            );
            continue;
        }
        const text = line[0..@min(line.len, shared.max_chat_len)];
        try self.network.sendCommand(
            .{ .chat = .{ .text_len = @intCast(text.len), .text = text } },
            .reliable,
        );
    }
}

/// Fires a particle effect 6 m in front of the camera (dev effects lab).
fn spawnEffectInView(self: *System, world: *World, name: []const u8) void {
    const effect = std.meta.stringToEnum(renderer_contract.ParticleEffect, name) orelse
        return std.log.info("fx: no effect '{s}'", .{name});
    const camera = world.camera.transform;
    const forward = camera.rotation.rotateVec(.{ 0, 0, -1 });
    const origin = camera.position + nz.vec.scale(forward, 6);
    const up = nz.vec.normalize(origin);
    const target = switch (effect) {
        .telegraph => origin + nz.vec.scale(up, 3),
        .lightning, .tracer, .heal_tracer => origin + nz.vec.scale(nz.vec.cross(forward, up), 4),
        else => origin,
    };
    self.particles.spawn(.{ .effect = effect, .origin = origin, .target = target }, world.elapsed_time);
}

/// Free camera into the nearest tunnel under the player (dev inspection).
fn flyIntoCave(world: *World) void {
    const player = world.getPtr(world.player_id) orelse return;
    const origin = player.transform.position;
    const up = nz.vec.normalize(origin);
    var best: ?nz.Vec3(f32) = null;
    var best_distance: f32 = std.math.inf(f32);
    var x: f32 = -60;
    while (x <= 60) : (x += 3) {
        var z: f32 = -60;
        while (z <= 60) : (z += 3) {
            var depth: f32 = 4;
            while (depth <= 20) : (depth += 2) {
                const point = origin + nz.Vec3(f32){ x, 0, z } - nz.vec.scale(up, depth);
                if (world.planet.sdf(point) < 1.5) continue;
                if (world.planet.terrain(point) > -3) continue;
                const distance = nz.vec.length(point - origin);
                if (distance < best_distance) {
                    best_distance = distance;
                    best = point;
                }
            }
        }
    }
    const point = best orelse return std.log.info("cave: none within 60 m", .{});
    const helper: nz.Vec3(f32) = if (@abs(up[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const tangent = nz.vec.normalize(nz.vec.cross(up, helper));
    const bitangent = nz.vec.cross(up, tangent);
    var view = tangent;
    var longest: f32 = 0;
    for (0..16) |sector| {
        const angle = std.math.tau * @as(f32, @floatFromInt(sector)) / 16;
        const direction = nz.vec.scale(tangent, @cos(angle)) + nz.vec.scale(bitangent, @sin(angle));
        var reach: f32 = 0;
        while (reach < 40 and world.planet.sdf(point + nz.vec.scale(direction, reach)) > 0.5) reach += 0.5;
        if (reach > longest) {
            longest = reach;
            view = direction;
        }
    }
    world.controller.free_camera = true;
    world.camera.transform.position = point;
    world.camera.yaw_rotation = .lookAt(view, up);
    world.camera.pitch = 0;
    std.log.info("cave: camera at {d:.1} {d:.1} {d:.1}", .{ point[0], point[1], point[2] });
}

const steam_input_manifest = "steam_input_manifest.vdf";

/// Writes the action manifest next to the exe's cwd and hands its absolute path to Steam Input.
fn startSteamInput(io: std.Io, gpa: std.mem.Allocator) shared.SteamInput {
    var buffer: [8 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    shared.SteamInput.writeManifest(&writer, &Controller.pad_names, &Controller.pad_titles) catch return .off;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = steam_input_manifest, .data = writer.buffered() }) catch |err| {
        std.log.warn("steam input manifest: {t}", .{err});
        return .off;
    };
    const cwd = std.process.currentPathAlloc(io, gpa) catch return .off;
    defer gpa.free(cwd);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ cwd, steam_input_manifest }, 0) catch return .off;
    defer gpa.free(path);
    return .start(path);
}

fn writeCatalog(self: *System, console_path: []const u8) void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}.catalog", .{console_path}) catch return;
    const buffer = self.gpa.alloc(u8, 256 * 1024) catch return;
    defer self.gpa.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    catalog.write(&writer) catch |err| return std.log.err("catalog: {t}", .{err});
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = writer.buffered() }) catch |err|
        std.log.err("catalog {s}: {t}", .{ path, err });
}

fn writeStateDump(self: *System, world: *World, console_path: []const u8) void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}.state", .{console_path}) catch return;
    var buffer: [8 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    dump.write(&writer, world, @tagName(self.scene), @tagName(self.hud.overlay)) catch {};
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = writer.buffered() }) catch |err|
        std.log.err("dump {s}: {t}", .{ path, err });
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
                    if (world.stage != 0) player_input = world.controller.update(self.window, self.pad);
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
        .zoo => if (self.window.keyboard.get(.escape) == .press) {
            try self.enterScene(world, .menu);
        } else {
            player_input = world.controller.update(self.window, self.pad);
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
            if (self.zoo.photo) try self.enterScene(world, .zoo);
        },
        .select_slot => |slot| {
            self.zoo.slot = slot;
            if (slot == .action) self.playZooAction(world);
        },
        .assign_clip => |clip| zoo_scene.assign(
            self.io,
            &self.assets.models,
            kind,
            self.zoo.slot,
            clip,
        ) catch |err|
            std.log.err("zoo: save manifest: {t}", .{err}),
        .play_action => self.playZooAction(world),
        .set_radius => |radius| {
            self.zoo.planet_radius = radius;
            try self.enterScene(world, .zoo);
        },
        .toggle_spin => self.zoo.spinning = !self.zoo.spinning,
        .focus => zoo_scene.focus(world, &self.zoo),
        .toggle_photo => {
            self.zoo.photo = !self.zoo.photo;
            try self.enterScene(world, .zoo);
        },
    }
}

fn playZooAction(self: *System, world: *World) void {
    const action = switch (self.zoo.slot) {
        .action => |action| action,
        .loop => return,
    };
    const models = &self.assets.models;
    const clip = models.rig(
        models.get(zoo_scene.kinds[self.zoo.kind_index]),
    ).action_clips.get(action) orelse return;
    self.animator.playOverlay(zoo_scene.subjectAnimation(world, &self.zoo), clip, models);
}

fn applyOptions(self: *System, world: *World) !void {
    try self.window.setFullscreen(world.options.fullscreen);
    self.audio.setVolume(world.options.master_volume);
    const playing = self.scene == .game and world.stage != 0 and self.hud.overlay == .none;
    const zoo_looking = self.scene == .zoo and self.window.pointer.buttons.right;
    const wants_cursor_lock = (playing or zoo_looking) and self.window.focused;
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
