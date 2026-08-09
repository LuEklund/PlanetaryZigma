const System = @This();

const std = @import("std");
const shared = @import("shared");
const shared_shader = @import("contract").Shader;
const tracy = @import("ztracy");
const nz = shared.numz;
const Window = @import("Window");
const NetworkManager = @import("system/NetworkManager.zig");
const render_system = @import("render_system");
const Assets = @import("Assets");
const Emitter = @import("render_system").Emitter;
const motion = @import("system/motion.zig");
const extract = @import("system/extract.zig");
const contract = @import("contract");
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
assets_dir: std.Io.Dir,
render: shared.HotLib(contract.Api, *anyopaque, "reload"),
draw_list: DrawList,
models: render_system.ModelTable,
fonts: [shared.Font.count]shared.Font,
assets: Assets,
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
    world: *World,
    steam_client: *shared.SteamNet.Client,
};

pub fn init(self: *System, data: Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.window = data.window;

    const assets_dir = try Assets.openDir(data.io);
    defer assets_dir.close(data.io);
    self.assets.init(data.gpa);
    // What this game owns. One row per file, and the index is what comes back when it
    // changes: a shader ordinal, a texture slot, a font index, a model row.
    for (std.enums.values(shared_shader.Kind)) |kind| {
        try self.assets.add(data.io, assets_dir, "shaders", shared_shader.get(kind).path, .shader, @intFromEnum(kind));
    }
    var texture_paths: [shared.Texture.paths_capacity][]const u8 = undefined;
    for (shared.Texture.paths(&texture_paths), 0..) |path, index| {
        try self.assets.add(data.io, assets_dir, "textures", path, .texture, @intCast(shared.Texture.reserved + index));
    }
    for (shared.Font.files, 0..) |path, index| {
        try self.assets.add(data.io, assets_dir, "fonts", path, .font, @intCast(index));
    }
    var model_paths: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (render_system.ModelTable.paths(&model_paths), 0..) |path, row| {
        // A generated model is a row with no file behind it, so it is never registered.
        if (!render_system.ModelTable.isFile(path)) continue;
        try self.assets.add(data.io, assets_dir, "objects", path["objects/".len..], .model, @intCast(row));
    }
    self.fonts = @splat(.empty);
    self.models = try .init(data.gpa);
    self.animator = try .init(data.gpa);
    errdefer self.animator.deinit();
    self.emitters = @splat(Emitter.free);

    self.render = try .init("render", data.gpa, data.io);
    errdefer self.render.deinit(data.io);
    self.render.handle = self.render.api.init(&contract.InitOptions{
        .gpa = data.gpa,
        .io = data.io,
        .window = @ptrCast(data.window),
        .first_dynamic_texture_slot = @intCast(shared.Texture.count()),
    }) orelse return error.RenderInit;
    errdefer self.render.api.deinit(self.render.handle);

    self.draw_list = try .init(data.gpa);
    errdefer self.draw_list.deinit(data.gpa);

    // render.so is up, so parsing can start; the uploads drain on the first frame.
    self.pollAssets(data.gpa, data.io);
    try render_system.upload.generated(data.gpa, &self.render, &self.models);

    try self.hud.init(data.gpa, data.window.size);
    errdefer self.hud.deinit(data.gpa);
    try self.network_manager.init(data.gpa, data.io, data.steam_client);
    errdefer self.network_manager.deinit();
    try self.enterScene(data.world, .menu);
    self.request_exit = false;
}

/// The three stages, in order: the watcher notices, a loader parses, the uploader sends.
fn pollAssets(self: *System, gpa: std.mem.Allocator, io: std.Io) void {
    var changed: [64]u32 = undefined;
    while (true) {
        const rows = self.assets.poll(io, &changed);
        for (rows) |entry| self.loadAsset(gpa, io, entry);
        // A first poll reports every file, and there are more of those than the buffer
        // holds, so keep going until a pass comes back short.
        if (rows.len < changed.len) break;
    }
}

fn loadAsset(self: *System, gpa: std.mem.Allocator, io: std.Io, entry: u32) void {
    const row = self.assets.entries.items[entry];
    switch (row.kind) {
        .shader => {
            const spirv = Assets.loader.shader(gpa, &self.assets, io, entry) catch |err| {
                std.log.err("shader {s}: {t}", .{ row.path, err });
                return;
            };
            defer gpa.free(spirv);
            self.render.api.uploadShader(self.render.handle, row.index, spirv.ptr, spirv.len);
        },
        .texture => {
            const cubemap = row.index == shared.Texture.slot(.skybox_cubemap);
            var decoded = Assets.loader.texture(gpa, &self.assets, io, entry, cubemap) catch |err| {
                std.log.warn("texture {s}: {t} - using fallback", .{ row.path, err });
                // An empty face list binds the checkerboard, so a file that would not decode
                // is visible rather than stale. A cube view has no 2D stand-in.
                if (cubemap) return;
                return self.render.api.uploadTexture(self.render.handle, &.{
                    .slot = row.index,
                    .width = 0,
                    .height = 0,
                    .faces = &.{},
                });
            };
            defer decoded.deinit(gpa);
            self.render.api.uploadTexture(self.render.handle, &.{
                .slot = row.index,
                .width = decoded.width,
                .height = decoded.height,
                .faces = decoded.faces,
            });
        },
        .font => {
            const baked = &self.fonts[row.index];
            const coverage = Assets.loader.font(baked, gpa, &self.assets, io, entry) catch |err| {
                std.log.err("font {s}: {t}", .{ row.path, err });
                return;
            };
            defer gpa.free(coverage);
            if (baked.atlas_texture_index != 0) {
                self.render.api.freeImage(self.render.handle, baked.atlas_texture_index);
            }
            baked.atlas_texture_index = self.render.api.uploadImage(self.render.handle, &.{
                .width = shared.Font.atlas_width,
                .height = shared.Font.atlas_height,
                .pixels = coverage,
                .r8 = true,
                .mips = false,
                .mag_linear = true,
                .min_linear = true,
            });
        },
        .model => self.loadModel(gpa, io, entry, row.index) catch |err| {
            std.log.err("model {s}: {t}", .{ row.path, err });
        },
    }
}

fn loadModel(self: *System, gpa: std.mem.Allocator, io: std.Io, entry: u32, row: u32) !void {
    const kind_spec = shared.entity.spec(render_system.ModelTable.kindForRow(row));
    const model_spec = kind_spec.model orelse return;
    const parsed_model = &self.models.models[row];

    var parsed = try Assets.loader.model(gpa, &self.assets, io, entry, parsed_model, model_spec.clip_names != null);
    defer parsed.deinit(gpa);

    try self.models.rigs[row].init(gpa, parsed_model, kind_spec, model_spec);
    try render_system.upload.model(gpa, &self.render, &self.models, parsed_model, &parsed, row);
}


pub fn deinit(self: *System) void {
    self.network_manager.deinit();
    self.hud.deinit(self.gpa);
    self.draw_list.deinit(self.gpa);
    self.animator.deinit();
    // Before the renderer: freeing a model's images is a call INTO render.so.
    self.assets.deinit(self.io);
    self.models.deinit(self.gpa);
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
    switch (try self.hud.update(world, self.scene, &self.network_manager, &world.options, &self.fonts[0])) {
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
    self.render.trySwap(self.io) catch |err| std.log.err("render swap: {s}", .{@errorName(err)});
    self.pollAssets(self.gpa, self.io);

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
