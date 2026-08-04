const Rendering = @This();

const std = @import("std");
const shared = @import("shared");
const Window = @import("Window");
const render = @import("render");
const Backend = render.Backend;
const AssetServer = render.AssetServer;
const FramePacket = render.FramePacket;
const Presentation = render.Presentation;

/// The renderer and everything that feeds it. `lib` and `handle` are always used
/// together, so nothing outside needs to see either — callers go through the functions
/// below.
lib: shared.HotLib(Backend.Table, *anyopaque, "renderInit", "renderReload"),
handle: *anyopaque,
packet: FramePacket,
presentation: Presentation,
/// CPU-side model data. Parsed by the renderer's loader, read here by `presentation`
/// for clips and skins — it lives on this side because `presentation` does.
models: Backend.ModelTable,

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    asset_server: *AssetServer,
    fonts: []render.Font,
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

    self.presentation = try .init(data.gpa);
    errdefer self.presentation.deinit();

    self.packet = try .init(data.gpa);
}

pub fn deinit(self: *Rendering, gpa: std.mem.Allocator, io: std.Io) void {
    self.packet.deinit(gpa);
    self.presentation.deinit();
    self.lib.symbols.renderDeinit(self.handle);
    self.lib.deinit(io);
    self.models.deinit(gpa);
}

pub fn submit(self: *Rendering) void {
    _ = self.lib.symbols.renderUpdate(self.handle, &self.packet);
}

/// Picks up a newer librender.so if one has been built. Safe to call every frame.
pub fn reloadChanged(self: *Rendering, io: std.Io) !void {
    try self.lib.swap(io, null, self.handle);
}
