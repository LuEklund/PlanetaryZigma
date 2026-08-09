//! The system's asset store: parsed models, baked fonts, and the four sources that keep them
//! current. The system owns this — the renderer is a door you push uploads through, not a
//! place to keep your models.
//!
//! Nothing rides the frame packet any more: every asset goes over as a call and comes back
//! as a handle or a slot.

const Assets = @This();

const std = @import("std");
const shared = @import("shared");
const assets = @import("assets");
const Font = @import("shared").Font;
const Texture = @import("shared").Texture;
const contract = @import("contract");
/// The loaded renderer library: its table and the state block it goes with.
const RenderLib = shared.HotLib(contract.Api, *anyopaque, "reload");

const DrawList = @import("contract").DrawList;

const ShaderSource = @import("Assets/ShaderSource.zig");
const TextureSource = @import("Assets/TextureSource.zig");
const FontSource = @import("Assets/FontSource.zig");
const ModelSource = @import("Assets/ModelSource.zig");

models: assets.ModelTable,
/// render.so fills in each atlas slot here; the memory is ours so it survives a swap.
fonts: [Font.count]Font,
shader_source: ShaderSource,
texture_source: TextureSource,
font_source: FontSource,
model_source: ModelSource,

/// Registers the sources. Nothing is read yet: the owner calls `asset_server.load()` once
/// the renderer exists, because the resulting uploads drain on the first frame.
pub fn init(
    self: *Assets,
    gpa: std.mem.Allocator,
    asset_server: *assets.AssetServer,
    renderer: *const RenderLib,
) !void {
    self.fonts = @splat(.empty);
    self.models = try .init(gpa);
    errdefer self.models.deinit(gpa);

    try self.shader_source.init(gpa, asset_server, renderer);
    errdefer self.shader_source.deinit();
    try self.texture_source.init(gpa, asset_server, renderer);
    errdefer self.texture_source.deinit();
    try self.font_source.init(gpa, asset_server, &self.fonts, renderer);
    errdefer self.font_source.deinit();
    try self.model_source.init(gpa, asset_server, &self.models, renderer);
}

pub fn deinit(self: *Assets, gpa: std.mem.Allocator) void {
    self.shader_source.deinit();
    self.texture_source.deinit();
    self.font_source.deinit();
    self.model_source.deinit();
    self.models.deinit(gpa);
}

/// The primitives are assets like any other: generated here, uploaded through the same
/// door. Call once, after the renderer exists.
pub fn uploadGenerated(self: *Assets, gpa: std.mem.Allocator, renderer: *const RenderLib) !void {
    const surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(assets.box.indices.len),
        .texture_slot = @intCast(Texture.slot(.blank)),
    }};
    var path_buffer: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (assets.ModelTable.paths(&path_buffer), 0..) |path, row| {
        if (assets.ModelTable.isFile(path)) continue;
        const handle = renderer.api.uploadMesh(renderer.handle, .none, &.{
            .name = path,
            .vertices = std.mem.sliceAsBytes(assets.box.vertices),
            .skinned = false,
            .indices = assets.box.indices,
            .surfaces = &surfaces,
        });
        const model = &self.models.models[row];
        model.mesh_handles = try gpa.alloc(usize, 1);
        model.mesh_handles[0] = @intFromEnum(handle);
        try model.surfaces.append(gpa, .{ .mesh_id = 0, .model_matrix = .identity });
    }
}
