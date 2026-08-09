const Viewer = @This();

const std = @import("std");
const shared = @import("shared");
const shared_shader = @import("contract").Shader;
const Window = @import("Window");
const contract = @import("contract");
const render_system = @import("render_system");
const Assets = @import("Assets");
const Emitter = @import("render_system").Emitter;
const Ui = @import("ui");
const DrawList = @import("contract").DrawList;
const World = @import("../World.zig");
const Quat = shared.numz.quat.Hamiltonian(f32);
const nz = shared.numz;
const extract = @import("extract.zig");
pub const Camera = @import("camera.zig");
const menu = @import("menu.zig");

render: shared.HotLib(contract.Api, *anyopaque, "reload"),
draw_list: DrawList,
window: *Window,
models: render_system.ModelTable,
fonts: [shared.Font.count]shared.Font,
assets: Assets,
animator: render_system.Animator,
emitters: Emitter.List,
camera: Camera,
ui: Ui,
menu_open: bool,
arrow_lines: std.ArrayList(DrawList.Line),
border_lines: std.ArrayList(DrawList.Line),
arrow_lines_field: ?u1,
border_lines_field: ?u1,

pub fn init(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, window: *Window, planet_radius: f32) !void {
    const assets_dir = try Assets.openDir(io);
    defer assets_dir.close(io);
    self.assets.init(gpa);
    // What this game owns. One row per file, and the index is what comes back when it
    // changes: a shader ordinal, a texture slot, a font index, a model row.
    for (std.enums.values(shared_shader.Kind)) |kind| {
        try self.assets.add(io, assets_dir, "shaders", shared_shader.get(kind).path, .shader, @intFromEnum(kind));
    }
    var texture_paths: [shared.Texture.paths_capacity][]const u8 = undefined;
    for (shared.Texture.paths(&texture_paths), 0..) |path, index| {
        try self.assets.add(io, assets_dir, "textures", path, .texture, @intCast(shared.Texture.reserved + index));
    }
    for (shared.Font.files, 0..) |path, index| {
        try self.assets.add(io, assets_dir, "fonts", path, .font, @intCast(index));
    }
    var model_paths: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (render_system.ModelTable.paths(&model_paths), 0..) |path, row| {
        // A generated model is a row with no file behind it, so it is never registered.
        if (!render_system.ModelTable.isFile(path)) continue;
        try self.assets.add(io, assets_dir, "objects", path["objects/".len..], .model, @intCast(row));
    }
    self.fonts = @splat(.empty);
    self.models = try .init(gpa);
    self.animator = try .init(gpa);
    errdefer self.animator.deinit();
    self.emitters = @splat(Emitter.free);

    self.window = window;
    self.render = try .init("render", gpa, io);
    errdefer self.render.deinit(io);
    self.render.handle = self.render.api.init(&contract.InitOptions{
        .gpa = gpa,
        .io = io,
        .window = @ptrCast(window),
        .first_dynamic_texture_slot = @intCast(shared.Texture.count()),
    }) orelse return error.RenderInit;
    errdefer self.render.api.deinit(self.render.handle);

    self.draw_list = try .init(gpa);
    errdefer self.draw_list.deinit(gpa);

    self.pollAssets(gpa, io);
    try render_system.upload.generated(gpa, &self.render, &self.models);

    self.ui = try .init(gpa, window.size.width, window.size.height);
    self.camera = .init(.{ 0, planet_radius * World.ship_room_altitude_factor, 30 });
    self.menu_open = true;
    self.arrow_lines = .empty;
    self.border_lines = .empty;
    self.arrow_lines_field = null;
    self.border_lines_field = null;
}

/// The three stages, in order: the watcher notices, a loader parses, the uploader sends.
fn pollAssets(self: *Viewer, gpa: std.mem.Allocator, io: std.Io) void {
    var changed: [64]u32 = undefined;
    while (true) {
        const rows = self.assets.poll(io, &changed);
        for (rows) |entry| self.loadAsset(gpa, io, entry);
        // A first poll reports every file, and there are more of those than the buffer
        // holds, so keep going until a pass comes back short.
        if (rows.len < changed.len) break;
    }
}

fn loadAsset(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, entry: u32) void {
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

fn loadModel(self: *Viewer, gpa: std.mem.Allocator, io: std.Io, entry: u32, row: u32) !void {
    const kind_spec = shared.entity.spec(render_system.ModelTable.kindForRow(row));
    const model_spec = kind_spec.model orelse return;
    const parsed_model = &self.models.models[row];

    var parsed = try Assets.loader.model(gpa, &self.assets, io, entry, parsed_model, model_spec.clip_names != null);
    defer parsed.deinit(gpa);

    try self.models.rigs[row].init(gpa, parsed_model, kind_spec, model_spec);
    try render_system.upload.model(gpa, &self.render, &self.models, parsed_model, &parsed, row);
}


pub fn deinit(self: *Viewer, gpa: std.mem.Allocator, io: std.Io) void {
    self.arrow_lines.deinit(gpa);
    self.border_lines.deinit(gpa);
    self.ui.deinit(gpa);
    self.draw_list.deinit(gpa);
    self.animator.deinit();
    // Before the renderer: freeing a model's images is a call INTO render.so.
    self.assets.deinit(io);
    self.models.deinit(gpa);
    self.render.api.deinit(self.render.handle);
    self.render.deinit(io);
}

/// Returns true when the window asks the server to stop.
pub fn draw(self: *Viewer, world: *World, io: std.Io) !bool {
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

    self.ui.screen_width = @floatFromInt(window.size.width);
    self.ui.screen_height = @floatFromInt(window.size.height);
    const pointer_position = switch (window.pointer.movement) {
        .position => |position| [2]f32{ @floatCast(position.x), @floatCast(position.y) },
        .relative => [2]f32{ 0, 0 },
    };
    self.ui.start(.{
        .position = .{ .left = pointer_position[0], .top = pointer_position[1] },
        .left_click = window.pointer.buttons.left,
        .right_click = window.pointer.buttons.right,
    }, &self.fonts[0], world.delta_time);
    var quit = window.should_close;
    if (self.menu_open and menu.update(&self.ui, world, std.mem.indexOfScalar(shared.entity.Id, world.players.items, self.camera.follow)))
        quit = true;
    self.ui.addText(null, self.ui.print("debug vertices {d}/{d}", .{
        (self.arrow_lines.items.len + self.border_lines.items.len) * 2,
        DrawList.max_lines * 2,
    }), 16, 8, 8);
    self.ui.end();

    if (world.options.draw_flow_field and self.arrow_lines_field != world.navmesh.internal.active) {
        try extract.collectNavmeshArrows(world, world.gpa, &self.arrow_lines);
        self.arrow_lines_field = world.navmesh.internal.active;
    }
    if (world.options.draw_chunk_borders and self.border_lines_field != world.navmesh.internal.active) {
        try extract.collectChunkBorders(world, world.gpa, &self.border_lines);
        self.border_lines_field = world.navmesh.internal.active;
    }

    try extract.frame(world, self);
    try self.render.trySwap(io);
    return quit;
}
