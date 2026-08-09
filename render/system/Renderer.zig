const Renderer = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const contract = @import("render");
const assets = @import("assets");
const AssetServer = @import("assets").AssetServer;
const DrawList = @import("render").DrawList;
const Animator = @import("Animator.zig");
const ShaderSource = @import("ShaderSource.zig");
const TextureSource = @import("TextureSource.zig");
const FontSource = @import("FontSource.zig");
const ModelSource = @import("ModelSource.zig");
const Emitter = @import("shared").Emitter;
const Shader = @import("shared").Shader;
const Ui = @import("shared").Ui;
const Font = @import("shared").Font;
const Texture = @import("shared").Texture;
const nz = shared.numz;

lib: shared.HotLib(contract.Table, *anyopaque, "renderInit", "renderReload"),
handle: *anyopaque,
list: DrawList,
window: *Window,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    /// Caller-owned: render.so writes atlas slots back into it, so it must outlive a swap.
    fonts: *[Font.count]Font,
};

pub fn init(self: *Renderer, data: Data) !void {
    self.window = data.window;
    self.lib = try .init("render", data.io);
    errdefer self.lib.deinit(data.io);

    self.handle = self.lib.symbols.renderInit(&contract.Data{
        .gpa = data.gpa,
        .io = data.io,
        .fonts = data.fonts,
        .window = data.window,
    }) orelse return error.RenderInit;
    errdefer self.lib.symbols.renderDeinit(self.handle);

    self.list = try .init(data.gpa);
}

pub fn deinit(self: *Renderer, gpa: std.mem.Allocator, io: std.Io) void {
    self.list.deinit(gpa);
    self.lib.symbols.renderDeinit(self.handle);
    self.lib.deinit(io);
}

pub const Frame = struct {
    camera: DrawList.Camera,
    elapsed_time: f32,
    light_color: [4]f32,
    draw_sky: bool,
    planet: DrawList.PlanetState,
    surface_width: u32,
    surface_height: u32,
};


pub fn beginFrame(self: *Renderer, frame: Frame) void {
    self.list.clear();
    self.list.camera = frame.camera;
    self.list.time = frame.elapsed_time;
    self.list.light_color = frame.light_color;
    self.list.draw_sky = frame.draw_sky;
    self.list.planet = frame.planet;
    self.list.surface_width = frame.surface_width;
    self.list.surface_height = frame.surface_height;
}

pub fn drawLine(self: *Renderer, a: nz.Vec3(f32), b: nz.Vec3(f32), color: [4]f32) void {
    self.list.draw_lines.appendAssumeCapacity(.{ .a = a, .b = b, .color = color });
}

pub fn drawLines(self: *Renderer, lines: []const DrawList.Line) void {
    self.list.draw_lines.appendSliceAssumeCapacity(lines);
}





pub fn drawUi(self: *Renderer, quads: []const Ui.Quad, screen_width: f32, screen_height: f32) void {
    self.list.ui.quads.appendSliceAssumeCapacity(quads);
    self.list.ui.screen_width = screen_width;
    self.list.ui.screen_height = screen_height;
}

/// Hand the packet to render.so. Uploads must already be published into `list`.
pub fn endFrame(self: *Renderer, emitters: *const Emitter.List, elapsed_time: f32) void {
    for (emitters) |emitter| {
        if (!emitter.alive(elapsed_time)) continue;
        self.list.emitters.appendAssumeCapacity(.{
            .effect = emitter.effect,
            .origin = emitter.origin,
            .target = emitter.target,
            .spawn_time = emitter.spawn_time,
        });
    }
    self.lib.symbols.renderUpdate(self.handle, &self.list);
}

pub fn reloadIfChanged(self: *Renderer, io: std.Io) !void {
    try self.lib.trySwap(io, self.handle);
}
