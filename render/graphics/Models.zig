const Models = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("renderer_contract");
const entity = shared.entity;
const assets = @import("assets/root.zig");
const gltf = @import("assets/types/gltf.zig");
const Model = @import("assets/root.zig").Model;
const Rig = @import("Rig.zig");
const ModelRow = @import("ModelRow.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

pub const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
    kind: ?entity.Kind,
    manifest: ?ModelRow,
    manifest_mtime: std.Io.Timestamp,
    /// `objects/<kind>.glb`: once that file exists it replaces a placeholder model.
    preferred_path: []const u8,
    preferred_mtime: std.Io.Timestamp,
    model: Model,
    rig: Rig,
    image_slots: []contract.TextureHandle,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),
reloaded: std.ArrayList(u32),

default: u32,
item_models: std.EnumArray(shared.Item.Kind, u32),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Models {
    var self: Models = .{
        .dir = try assets.openDir(io),
        .entries = .empty,
        .reloaded = .empty,
        .default = 0,
        .item_models = .initFill(0),
    };
    errdefer self.deinit(gpa, io);

    self.default = try self.add(gpa, "", null);
    for (entity.all_kinds, preferred_paths) |kind, preferred| {
        const model_spec = kind.modelSpec() orelse continue;
        const handle = try self.add(gpa, model_spec.path, kind);
        self.entries.items[handle].preferred_path = preferred;
    }
    for (std.enums.values(shared.Item.Kind)) |item_kind| {
        const handle = try self.add(
            gpa,
            shared.Item.model_paths[@intFromEnum(item_kind)],
            null,
        );
        self.item_models.set(item_kind, handle);
    }
    return self;
}

/// Where a dropped-in model for each kind is looked for (also what the Lucas TODO board shows).
const preferred_paths: [entity.all_kinds.len][]const u8 = paths: {
    var paths: [entity.all_kinds.len][]const u8 = undefined;
    for (entity.all_kinds, &paths) |kind, *path| {
        const name = switch (kind) {
            .enemy => |enemy| @tagName(enemy),
            else => @tagName(kind),
        };
        path.* = "objects/" ++ name ++ ".glb";
    }
    break :paths paths;
};

pub fn getItem(self: *const Models, item: shared.Item.Kind) u32 {
    return self.item_models.get(item);
}

pub fn deinit(self: *Models, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    for (self.entries.items) |*entry| {
        entry.rig.deinit(gpa);
        if (entry.manifest) |manifest| ModelRow.free(gpa, manifest);
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
        .manifest = null,
        .manifest_mtime = .zero,
        .preferred_path = "",
        .preferred_mtime = .zero,
        .model = .empty,
        .rig = .empty,
        .image_slots = &.{},
    });
    return handle;
}

pub fn get(self: *const Models, kind: entity.Kind) u32 {
    for (self.entries.items, 0..) |entry, handle| {
        if (entry.kind) |owner| {
            if (std.meta.eql(owner, kind)) return @intCast(handle);
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

/// The kind's presentation: its manifest file if one exists, else its Zig spec.
pub fn row(self: *const Models, handle: u32) ?ModelRow {
    const entry = &self.entries.items[handle];
    if (entry.manifest) |manifest| return manifest;
    return ModelRow.fromSpec(entry.kind orelse return null);
}

pub fn update(self: *Models, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items, 0..) |*entry, handle| {
        const manifest_changed = try self.updateManifest(gpa, io, entry);
        self.adoptPreferredModel(io, entry);
        const model_changed = entry.path.len > 0 and assets.changed(
            io,
            self.dir,
            entry.path,
            &entry.mtime,
        );
        if (model_changed) {
            if (!try self.reloadModel(gpa, io, renderer, entry)) continue;
            try self.reloaded.append(gpa, @intCast(handle));
        }
        const placeholder_first_time = entry.path.len == 0 and entry.mtime.nanoseconds == 0;
        if (placeholder_first_time) entry.mtime = .{ .nanoseconds = 1 };
        if (!model_changed and !manifest_changed and !placeholder_first_time) continue;
        const kind = entry.kind orelse continue;
        const current = self.row(@intCast(handle)) orelse continue;
        entry.rig.init(gpa, &entry.model, &current, kind.spec()) catch |err|
            std.log.err("{s}: {t}, fix its manifest or spec", .{ entry.path, err });
    }
}

/// Switches to `objects/<kind>.glb` when it exists and no manifest picked a model.
fn adoptPreferredModel(self: *Models, io: std.Io, entry: *Entry) void {
    if (entry.manifest != null or entry.preferred_path.len == 0) return;
    if (std.mem.eql(u8, entry.path, entry.preferred_path)) return;
    if (!assets.changed(io, self.dir, entry.preferred_path, &entry.preferred_mtime)) return;
    std.log.info("model {s} found, replacing the placeholder", .{entry.preferred_path});
    entry.path = entry.preferred_path;
    entry.mtime = .zero;
}

fn updateManifest(self: *Models, gpa: std.mem.Allocator, io: std.Io, entry: *Entry) !bool {
    const kind = entry.kind orelse return false;
    var path_buffer: [256]u8 = undefined;
    const path = try ModelRow.filePath(&path_buffer, kind);
    if (!assets.changed(io, self.dir, path, &entry.manifest_mtime)) return false;
    const source = self.dir.readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        std.log.err("{s}: {t}", .{ path, err });
        return false;
    };
    defer gpa.free(source);
    const fresh = ModelRow.parse(gpa, source) catch return false;
    if (!std.mem.eql(u8, fresh.model, entry.path)) entry.mtime = .zero;
    entry.path = fresh.model;
    if (entry.manifest) |old| ModelRow.free(gpa, old);
    entry.manifest = fresh;
    std.log.info("manifest {s} loaded", .{path});
    return true;
}

fn reloadModel(
    self: *Models,
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *const RenderLib,
    entry: *Entry,
) !bool {
    const bytes = try assets.read(gpa, io, self.dir, entry.path);
    defer gpa.free(bytes);

    var fresh: Model = .empty;
    var parsed = glb(gpa, bytes, &fresh) catch |err| {
        std.log.warn("model {s}: {t} - keeping the one already loaded", .{ entry.path, err });
        fresh.deinit(gpa);
        return false;
    };
    defer parsed.deinit(gpa);

    for (entry.model.mesh_handles) |mesh| {
        if (mesh != 0) renderer.api.freeMesh(renderer.handle, @enumFromInt(mesh));
    }
    for (entry.image_slots) |texture| renderer.api.freeImage(renderer.handle, texture);
    gpa.free(entry.image_slots);
    entry.image_slots = &.{};
    entry.model.deinit(gpa);
    entry.model = fresh;
    try uploadMeshes(gpa, renderer, entry, &parsed);
    return true;
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

fn glb(gpa: std.mem.Allocator, bytes: []const u8, model: *Model) !Parsed {
    if (!model.isEmpty()) model.deinit(gpa);
    model.* = .empty;

    var parsed_glb: gltf.Glb = try .parse(gpa, bytes);
    defer parsed_glb.deinit(gpa);

    return if (parsed_glb.isSkinned())
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, &parsed_glb) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, &parsed_glb) };
}
