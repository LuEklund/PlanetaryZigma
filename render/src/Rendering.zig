const Rendering = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const Backend = @import("Backend.zig");
const AssetServer = @import("AssetServer.zig");
const DrawList = @import("Renderer/DrawList.zig");
const Animator = @import("Animator.zig");
const Emitter = @import("Emitter.zig");
const Shader = @import("Renderer/Vulkan/Shader.zig");
const Ui = @import("Ui.zig");
const Font = @import("asset/Font.zig");
const nz = shared.numz;

/// The renderer and everything that feeds it. `lib` and `handle` are always used
/// together, so nothing outside needs to see either — callers go through the functions
/// below.
lib: shared.HotLib(Backend.Table, *anyopaque, "renderInit", "renderReload"),
handle: *anyopaque,
/// The frame being built. Private on purpose — producers go through the draw calls
/// below, so nothing outside has to know how draws are stored.
list: DrawList,
animator: Animator,
emitters: Emitter.List,
/// CPU-side model data. Parsed by the renderer's loader, read here by `animator`
/// for clips and skins — it lives on this side because `animator` does.
models: Backend.ModelTable,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    asset_server: *AssetServer,
    fonts: []Font,
    texture_slots: []u32,
};

pub fn init(self: *Rendering, data: Data) !void {
    self.models = try .init(data.gpa);
    errdefer self.models.deinit(data.gpa);

    self.lib = try .init("render", data.io);
    errdefer self.lib.deinit(data.io);

    self.handle = self.lib.symbols.renderInit(&Backend.Data{
        .gpa = data.gpa,
        .io = data.io,
        .asset_server = data.asset_server,
        .fonts = data.fonts,
        .models = &self.models,
        .texture_slots = data.texture_slots,
        .window = data.window,
    }) orelse return error.RenderInit;
    errdefer self.lib.symbols.renderDeinit(self.handle);

    self.animator = try .init(data.gpa);
    errdefer self.animator.deinit();

    self.list = try .init(data.gpa);
    self.emitters = @splat(Emitter.free);
}

pub fn deinit(self: *Rendering, gpa: std.mem.Allocator, io: std.Io) void {
    self.list.deinit(gpa);
    self.animator.deinit();
    self.lib.symbols.renderDeinit(self.handle);
    self.lib.deinit(io);
    self.models.deinit(gpa);
}

/// Frame-wide state, set once at the start of a frame.
pub const Frame = struct {
    camera: DrawList.Camera,
    elapsed_time: f32,
    light_color: [4]f32,
    draw_sky: bool,
    planet: DrawList.PlanetState,
    surface_width: u32,
    surface_height: u32,
};

pub fn beginFrame(self: *Rendering, frame: Frame) void {
    self.list.clear();
    self.list.camera = frame.camera;
    self.list.time = frame.elapsed_time;
    self.list.light_color = frame.light_color;
    self.list.draw_sky = frame.draw_sky;
    self.list.planet = frame.planet;
    self.list.surface_width = frame.surface_width;
    self.list.surface_height = frame.surface_height;
}

pub fn drawModel(self: *Rendering, draw: DrawList.DrawModel) void {
    self.list.draw_models.appendAssumeCapacity(draw);
}

/// Uploads a skin's matrices and returns where they landed, for `DrawModel.palette_offset`.
pub fn drawJoints(self: *Rendering, matrices: []const nz.Mat4x4(f32)) u32 {
    const offset: u32 = @intCast(self.list.joint_matrices.items.len);
    self.list.joint_matrices.appendSliceAssumeCapacity(matrices);
    return offset;
}

pub fn drawLine(self: *Rendering, a: nz.Vec3(f32), b: nz.Vec3(f32), color: [4]f32) void {
    self.list.draw_lines.appendAssumeCapacity(.{ .a = a, .b = b, .color = color });
}

pub fn spawnEffect(self: *Rendering, request: Emitter.Spawn, elapsed_time: f32) void {
    Emitter.spawn(&self.emitters, request, elapsed_time);
}

pub fn keepAliveEffect(self: *Rendering, effect: Shader.Kind, owner: shared.entity.Id, origin: nz.Vec3(f32), elapsed_time: f32) void {
    Emitter.keepAlive(&self.emitters, effect, owner, origin, elapsed_time);
}

pub fn advanceAnimation(self: *Rendering, triggers: []const shared.net.Event.Trigger) void {
    self.animator.advance(triggers, &self.models);
}

pub fn drawAnimated(self: *Rendering) void {
    self.animator.draw(&self.list, &self.emitters);
}

pub fn drawUi(self: *Rendering, quads: []const Ui.Quad, screen_width: f32, screen_height: f32) void {
    self.list.ui.quads.appendSliceAssumeCapacity(quads);
    self.list.ui.screen_width = screen_width;
    self.list.ui.screen_height = screen_height;
}

pub fn command(self: *Rendering, value: DrawList.RenderCommand) void {
    self.list.commands.appendAssumeCapacity(value);
}

/// Emits the live emitters and hands the frame to the renderer.
pub fn endFrame(self: *Rendering, elapsed_time: f32) void {
    for (&self.emitters) |emitter| {
        if (!emitter.alive(elapsed_time)) continue;
        self.list.emitters.appendAssumeCapacity(.{
            .effect = emitter.effect,
            .origin = emitter.origin,
            .target = emitter.target,
            .spawn_time = emitter.spawn_time,
        });
    }
    _ = self.lib.symbols.renderUpdate(self.handle, &self.list);
}

/// Picks up a newer librender.so if one has been built. Safe to call every frame.
pub fn reloadChanged(self: *Rendering, io: std.Io) !void {
    try self.lib.swap(io, null, self.handle);
}
