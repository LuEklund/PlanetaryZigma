//! The model files, what the parse produced, and the rig each one is read against.
//!
//! `Animator` takes this and reads `models`, `rigs` and `reloaded`. The files and the image
//! slots are the loader's half — nothing downstream touches either.

const Models = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const entity = shared.entity;
const assets = @import("assets/root.zig");
const gltf = @import("assets/types/gltf.zig");
const Model = @import("assets/root.zig").Model;
const Rig = @import("Rig.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

pub const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
    /// Which kind named this file first. The specs it loads against come from here.
    kind: entity.Kind,
    model: Model,
    /// The entity spec read against the model's own node names. No .glb holds any of it.
    rig: Rig,
    /// Texture slots the backend handed back for the embedded images. Ours to free on a
    /// reload, because the backend allocated them at our request.
    image_slots: []u32,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),
/// Handles whose file changed since the animator last looked. It drains this.
reloaded: std.ArrayList(u32),

/// One pass over the specs: a distinct model file IS a handle, and the kind that named it first
/// is the one its spec is read against. Two kinds sharing a .glb share a handle, or the same
/// file would be parsed and uploaded twice.
pub fn init(gpa: std.mem.Allocator, io: std.Io) !Models {
    const root = try assets.openDir(io);
    defer root.close(io);
    var self: Models = .{
        .dir = try root.openDir(io, "objects", .{}),
        .entries = .empty,
        .reloaded = .empty,
    };
    errdefer self.deinit(gpa, io);

    for (entity.all_kinds) |kind| {
        const model_spec = entity.modelSpec(kind) orelse continue;
        const file = if (std.mem.startsWith(u8, model_spec.path, "objects/")) model_spec.path["objects/".len..] else model_spec.path;
        if (self.get(kind) != null) continue;
        _ = try self.add(gpa, file, kind);
    }
    return self;
}

pub fn deinit(self: *Models, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    for (self.entries.items) |*entry| {
        entry.rig.deinit(gpa);
        gpa.free(entry.image_slots);
        // An entry owns nodes, node names, clips, skins and surfaces. Freeing the array alone
        // leaks all of it — one allocation per node name, per clip, per skin.
        entry.model.deinit(gpa);
    }
    self.entries.deinit(gpa);
    self.reloaded.deinit(gpa);
}

pub fn add(self: *Models, gpa: std.mem.Allocator, path: []const u8, kind: entity.Kind) !u32 {
    const handle: u32 = @intCast(self.entries.items.len);
    try self.entries.append(gpa, .{
        .path = path,
        .mtime = .zero,
        .kind = kind,
        .model = .empty,
        .rig = .empty,
        .image_slots = &.{},
    });
    return handle;
}

/// Which handle a kind draws from. A walk over a few dozen rows, and it stays that way — the
/// alternative is a map keyed by a tagged union for a table this size.
pub fn get(self: *const Models, kind: entity.Kind) ?u32 {
    const wanted = (entity.modelSpec(kind) orelse return null).path;
    for (self.entries.items, 0..) |entry, handle| {
        // Every entry got here by having one, so this cannot be null.
        if (std.mem.eql(u8, entity.modelSpec(entry.kind).?.path, wanted)) return @intCast(handle);
    }
    return null;
}

pub fn modelPtr(self: *const Models, handle: u32) *const Model {
    return &self.entries.items[handle].model;
}

pub fn rig(self: *const Models, handle: u32) *const Rig {
    return &self.entries.items[handle].rig;
}

pub fn update(self: *Models, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items, 0..) |*entry, handle| {
        // A model with no file behind it never changes, so it is the one entry that never has
        // a mesh. That is the whole condition — no flag, and it heals itself if it failed.
        if (!std.mem.endsWith(u8, entry.path, ".glb")) {
            if (entry.model.mesh_handles.len == 0) try uploadBox(gpa, renderer, entry);
            continue;
        }
        if (!assets.changed(io, self.dir, entry.path, &entry.mtime)) continue;

        const kind_spec = entity.spec(entry.kind);
        const model_spec = kind_spec.model orelse continue;
        const bytes = try assets.read(gpa, io, self.dir, entry.path);
        defer gpa.free(bytes);

        // Everything the last load put on the GPU goes first, and it has to go BEFORE the
        // parse: that resets the entry, and the mesh handles are the only record of what to
        // free. The entry names new ones a few lines down.
        for (entry.model.mesh_handles) |mesh| {
            if (mesh != 0) renderer.api.freeMesh(renderer.handle, @enumFromInt(mesh));
        }
        for (entry.image_slots) |slot| renderer.api.freeImage(renderer.handle, slot);
        gpa.free(entry.image_slots);
        entry.image_slots = &.{};

        var parsed = try glb(gpa, bytes, &entry.model, model_spec.clip_names != null);
        defer parsed.deinit(gpa);
        try entry.rig.init(gpa, &entry.model, kind_spec, model_spec);

        try uploadMeshes(gpa, renderer, entry, &parsed);
        try self.reloaded.append(gpa, @intCast(handle));
    }
}

/// The primitives are assets like any other: generated here, uploaded through the same door.
fn uploadBox(gpa: std.mem.Allocator, renderer: *const RenderLib, entry: *Entry) !void {
    const surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(assets.box.indices.len),
        .texture_slot = contract.blank_texture,
    }};
    const mesh_handle = renderer.api.uploadMesh(renderer.handle, .none, &.{
        .name = entry.path,
        .vertices = std.mem.sliceAsBytes(assets.box.vertices),
        .skinned = false,
        .indices = assets.box.indices,
        .surfaces = &surfaces,
    });
    entry.model.mesh_handles = try gpa.alloc(usize, 1);
    entry.model.mesh_handles[0] = @intFromEnum(mesh_handle);
    try entry.model.surfaces.append(gpa, .{ .mesh_id = 0, .model_matrix = .identity });
}

/// Images first, because a surface names the slot one of them landed in.
fn uploadMeshes(
    gpa: std.mem.Allocator,
    renderer: *const RenderLib,
    entry: *Entry,
    parsed: *const Parsed,
) !void {
    switch (parsed.*) {
        inline else => |*data, tag| {
            const slots = try gpa.alloc(u32, data.images.len);
            errdefer gpa.free(slots);
            for (data.images, data.image_sampler, slots) |image, sampler_index, *slot| {
                const sampler = if (sampler_index) |sampler| data.samplers[sampler] else null;
                const width: u32 = @intCast(image.width);
                const height: u32 = @intCast(image.height);
                slot.* = renderer.api.uploadImage(renderer.handle, 0, &.{
                    .width = width,
                    .height = height,
                    .pixels = image.pixels[0 .. width * height * 4],
                    .r8 = false,
                    .mips = true,
                    .mag_linear = if (sampler) |desc| desc.mag_linear else true,
                    .min_linear = if (sampler) |desc| desc.min_linear else true,
                });
            }
            entry.image_slots = slots;

            const handles = try gpa.alloc(usize, data.meshes.len);
            errdefer gpa.free(handles);
            for (data.meshes, handles) |mesh, *mesh_handle| {
                const surfaces = try gpa.alloc(contract.SurfaceUpload, mesh.surfaces.len);
                defer gpa.free(surfaces);
                for (mesh.surfaces, surfaces) |src, *surface| surface.* = .{
                    .index_start = src.index_start,
                    .index_count = src.index_count,
                    .texture_slot = if (src.material_missing)
                        contract.missing_texture
                    else if (src.image_index) |image_index|
                        slots[image_index]
                    else
                        contract.blank_texture,
                };
                mesh_handle.* = @intFromEnum(renderer.api.uploadMesh(renderer.handle, .none, &.{
                    .name = mesh.name,
                    .vertices = std.mem.sliceAsBytes(mesh.vertices),
                    .skinned = tag == .skinned,
                    .indices = mesh.indices,
                    .surfaces = surfaces,
                }));
            }
            entry.model.mesh_handles = handles;
        },
    }
}

/// What came out of the file and still has to reach a GPU: vertices, indices, and any
/// images the glb embedded. The CPU half went straight into the `Model`.
const Parsed = union(enum) {
    static: gltf.UploadData(shared.StaticVertex),
    skinned: gltf.UploadData(shared.SkinnedVertex),

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*variant| variant.deinit(gpa),
        }
    }
};

/// `skinned` picks the vertex layout to produce. The file decides whether it HAS skins; the
/// caller decides which layout it wants the vertices in.
fn glb(gpa: std.mem.Allocator, bytes: []const u8, model: *Model, skinned: bool) !Parsed {
    if (!model.isEmpty()) model.deinit(gpa);
    model.* = .empty;

    return if (skinned)
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, bytes) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, bytes) };
}
