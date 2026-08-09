//! The system's asset store: parsed models, baked fonts, and the four sources that keep them
//! current. The system owns this — the renderer is a door you push uploads through, not a
//! place to keep your models.
//!
//! `publish` is the only thing that touches the frame packet, and it hands over slices that
//! stay valid until `consumed`.

const Assets = @This();

const std = @import("std");
const assets = @import("assets");
const Font = @import("shared").Font;
const DrawList = @import("render").DrawList;

const ShaderSource = @import("Assets/ShaderSource.zig");
const TextureSource = @import("Assets/TextureSource.zig");
const FontSource = @import("Assets/FontSource.zig");
const ModelSource = @import("Assets/ModelSource.zig");

models: assets.ModelTable,
/// render.so fills in each atlas slot here; the memory is ours so it survives a swap.
fonts: [Font.count]Font,
/// Every source appends here. One queue in, one switch out.
pending: std.ArrayList(DrawList.AssetUpload),
shader_source: ShaderSource,
texture_source: TextureSource,
font_source: FontSource,
model_source: ModelSource,

/// Registers the sources. Nothing is read yet: the owner calls `asset_server.load()` once
/// the renderer exists, because the resulting uploads drain on the first frame.
pub fn init(self: *Assets, gpa: std.mem.Allocator, asset_server: *assets.AssetServer) !void {
    self.fonts = @splat(.empty);
    self.pending = .empty;
    self.models = try .init(gpa);
    errdefer self.models.deinit(gpa);

    try self.shader_source.init(gpa, asset_server, &self.pending);
    errdefer self.shader_source.deinit();
    try self.texture_source.init(gpa, asset_server, &self.pending);
    errdefer self.texture_source.deinit();
    try self.font_source.init(gpa, asset_server, &self.fonts, &self.pending);
    errdefer self.font_source.deinit();
    try self.model_source.init(gpa, asset_server, &self.models, &self.pending);
}

pub fn deinit(self: *Assets, gpa: std.mem.Allocator) void {
    self.shader_source.deinit();
    self.texture_source.deinit();
    self.font_source.deinit();
    self.model_source.deinit();
    self.pending.deinit(gpa);
    self.models.deinit(gpa);
}

pub fn publish(self: *const Assets, list: *DrawList) void {
    list.asset_uploads = self.pending.items;
}

pub fn consumed(self: *Assets) void {
    self.pending.clearRetainingCapacity();
}
