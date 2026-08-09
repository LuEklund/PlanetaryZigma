//! Parses glTF on THIS side of the boundary. Twin of ShaderSource/TextureSource/FontSource.
//!
//! The CPU `Model` (nodes, skins, clips) is written straight into the caller-owned
//! `ModelTable`, which already lives above the boundary; only mesh geometry and embedded
//! images travel as an upload. The backend returns image slots by filling its own Entry.

const ModelSource = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const AssetServer = @import("AssetServer.zig");
const DrawList = @import("DrawList.zig");
const ModelTable = @import("asset/ModelTable.zig");

const Loader = AssetServer.Loader;

gpa: std.mem.Allocator,
models: *ModelTable,
kinds: []entity.Kind,
owned: []?DrawList.ModelUpload.Data,
pending: std.ArrayList(DrawList.ModelUpload),
interface: Loader,

pub fn init(self: *ModelSource, gpa: std.mem.Allocator, asset_server: *AssetServer, models: *ModelTable) !void {
    var path_buffer: [entity.all_kinds.len][]const u8 = undefined;
    const model_paths = ModelTable.pathsByFileIndex(&path_buffer);
    const files = try gpa.alloc([]const u8, model_paths.len);
    const kinds = try gpa.alloc(entity.Kind, model_paths.len);
    for (model_paths, kinds, files) |path, *kind, *file| {
        kind.* = kindForPath(path);
        file.* = path["objects/".len..];
    }

    self.* = .{
        .gpa = gpa,
        .models = models,
        .kinds = kinds,
        .owned = try gpa.alloc(?DrawList.ModelUpload.Data, model_paths.len),
        .pending = .empty,
        .interface = .{
            .gpa = gpa,
            .io = asset_server.io,
            .root_path = "objects",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
    @memset(self.owned, null);
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *ModelSource) void {
    for (self.owned) |*slot| if (slot.*) |*data| free(data, self.gpa);
    self.gpa.free(self.owned);
    self.gpa.free(self.kinds);
    self.pending.deinit(self.gpa);
    self.gpa.free(self.interface.files);
}

pub fn uploads(self: *const ModelSource) []const DrawList.ModelUpload {
    return self.pending.items;
}

pub fn consumed(self: *ModelSource) void {
    self.pending.clearRetainingCapacity();
}

fn free(data: *DrawList.ModelUpload.Data, gpa: std.mem.Allocator) void {
    switch (data.*) {
        inline else => |*variant| variant.deinit(gpa),
    }
}

fn kindForPath(path: []const u8) entity.Kind {
    for (entity.all_kinds) |kind| {
        const model_spec = entity.spec(kind).model orelse continue;
        if (std.mem.eql(u8, model_spec.path, path)) return kind;
    }
    unreachable;
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ModelSource = @fieldParentPtr("interface", loader);
    const gpa = self.gpa;
    const file = try err_file;

    const model = &self.models.models[index];
    const kind_spec = entity.spec(self.kinds[index]);
    const model_spec = kind_spec.model orelse return;

    if (!model.isEmpty()) model.deinit(gpa);
    model.* = .empty;

    const data: DrawList.ModelUpload.Data = if (model_spec.clip_names != null)
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, loader.io, file, kind_spec, model_spec) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, loader.io, file, kind_spec, model_spec) };

    if (self.owned[index]) |*old| {
        for (self.pending.items) |*upload| {
            if (upload.index != index) continue;
            upload.data = data;
            break;
        }
        free(old, gpa);
    }
    self.owned[index] = data;

    for (self.pending.items) |upload| if (upload.index == index) {
        try self.models.reloaded.append(gpa, @intCast(index));
        return;
    };
    try self.pending.append(gpa, .{ .index = @intCast(index), .data = data });
    try self.models.reloaded.append(gpa, @intCast(index));
}

fn unload(loader: *Loader, index: usize) void {
    _ = loader;
    _ = index;
    // Parsed data stays owned until the next load replaces it; meshes, images and slots are
    // the backend's to release when it applies the next upload.
}
