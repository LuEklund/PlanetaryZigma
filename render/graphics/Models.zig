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
    kind: ?entity.Kind,
    model: Model,
    rig: Rig,
    image_slots: []contract.TextureHandle,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),
reloaded: std.ArrayList(u32),

default: u32,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Models {
    const root = try assets.openDir(io);
    defer root.close(io);
    var self: Models = .{
        .dir = try root.openDir(io, "objects", .{}),
        .entries = .empty,
        .reloaded = .empty,
        .default = 0,
    };
    errdefer self.deinit(gpa, io);

    self.default = try self.add(gpa, "", null);
    for (entity.all_kinds) |kind| {
        const model_spec = entity.modelSpec(kind) orelse continue;
        _ = try self.add(gpa, std.fs.path.basename(model_spec.path), kind);
    }
    return self;
}

pub fn deinit(self: *Models, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    for (self.entries.items) |*entry| {
        entry.rig.deinit(gpa);
        gpa.free(entry.image_slots);
        entry.model.deinit(gpa);
    }
    self.entries.deinit(gpa);
    self.reloaded.deinit(gpa);
}

pub fn add(self: *Models, gpa: std.mem.Allocator, path: []const u8, kind: ?entity.Kind) !u32 {
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

pub fn get(self: *const Models, kind: entity.Kind) u32 {
    for (self.entries.items, 0..) |entry, handle| {
        if (entry.kind) |owner| {
            if (owner.eql(kind)) return @intCast(handle);
        }
    }
    return self.default;
}

pub fn modelPtr(self: *const Models, handle: u32) *const Model {
    return &self.entries.items[handle].model;
}

pub fn rig(self: *const Models, handle: u32) *const Rig {
    return &self.entries.items[handle].rig;
}

pub fn update(self: *Models, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items, 0..) |*entry, handle| {
        if (entry.path.len == 0) continue;
        if (!assets.changed(io, self.dir, entry.path, &entry.mtime)) continue;

        const kind_spec: ?entity.Spec = if (entry.kind) |kind| entity.spec(kind) else null;
        const model_spec: ?entity.ModelSpec = if (kind_spec) |spec| (spec.model orelse continue) else null;
        const bytes = try assets.read(gpa, io, self.dir, entry.path);
        defer gpa.free(bytes);

        var fresh: Model = .empty;
        var parsed = glb(gpa, bytes, &fresh, if (model_spec) |spec| spec.loop_clips != null or spec.action_clips != null else false) catch |err| {
            std.log.warn("model {s}: {t} - keeping the one already loaded", .{ entry.path, err });
            fresh.deinit(gpa);
            continue;
        };
        defer parsed.deinit(gpa);

        // The new data is good, so the old can go. The mesh handles are the only record of
        // what this entry put on the GPU, which is why they are read before being replaced.
        for (entry.model.mesh_handles) |mesh| {
            if (mesh != 0) renderer.api.freeMesh(renderer.handle, @enumFromInt(mesh));
        }
        for (entry.image_slots) |texture| renderer.api.freeImage(renderer.handle, texture);
        gpa.free(entry.image_slots);
        entry.image_slots = &.{};
        entry.model.deinit(gpa);
        entry.model = fresh;

        if (kind_spec) |spec| try entry.rig.init(gpa, &entry.model, spec, model_spec.?);
        try uploadMeshes(gpa, renderer, entry, &parsed);
        try self.reloaded.append(gpa, @intCast(handle));
    }
}

fn uploadMeshes(
    gpa: std.mem.Allocator,
    renderer: *const RenderLib,
    entry: *Entry,
    parsed: *const Parsed,
) !void {
    switch (parsed.*) {
        inline else => |*data, tag| {
            const slots = try gpa.alloc(contract.TextureHandle, data.images.len);
            errdefer gpa.free(slots);
            for (data.images, data.image_sampler, slots) |image, sampler_index, *slot| {
                const sampler = if (sampler_index) |sampler| data.samplers[sampler] else null;
                const width: u32 = @intCast(image.width);
                const height: u32 = @intCast(image.height);
                slot.* = renderer.api.uploadImage(renderer.handle, &.{
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
                    .transparent = src.transparent,
                    .texture = if (src.material_missing)
                        .missing
                    else if (src.image_index) |image_index|
                        slots[image_index]
                    else
                        .blank,
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

const Parsed = union(enum) {
    static: gltf.UploadData(shared.StaticVertex),
    skinned: gltf.UploadData(shared.SkinnedVertex),

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*variant| variant.deinit(gpa),
        }
    }
};

fn glb(gpa: std.mem.Allocator, bytes: []const u8, model: *Model, skinned: bool) !Parsed {
    if (!model.isEmpty()) model.deinit(gpa);
    model.* = .empty;

    return if (skinned)
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, bytes) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, bytes) };
}
