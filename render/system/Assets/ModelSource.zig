//! Parses glTF on THIS side of the boundary. Twin of ShaderSource/TextureSource/FontSource.
//!
//! The CPU `Model` (nodes, skins, clips) is written straight into the caller-owned
//! `ModelTable`, which already lives above the boundary; only mesh geometry and embedded
//! images travel as an upload. The backend returns image slots by filling its own Entry.

const ModelSource = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const AssetServer = @import("assets").AssetServer;
const DrawList = @import("render").DrawList;
const ModelTable = @import("assets").ModelTable;
const contract = @import("render");

const Loader = AssetServer.Loader;
const gltf = @import("assets").gltf;

/// glTF keeps its own generic shape; the contract does not name it. This is the adapter.
const Parsed = union(enum) {
    static: gltf.UploadData(shared.StaticVertex),
    skinned: gltf.UploadData(shared.SkinnedVertex),
};

const Descriptors = struct {
    meshes: []DrawList.MeshUpload,
    surfaces: [][]DrawList.SurfaceUpload,
    images: []DrawList.ImageUpload,
    samplers: []DrawList.SamplerUpload,
};

gpa: std.mem.Allocator,
models: *ModelTable,
kinds: []entity.Kind,
owned: []?Parsed,
/// Descriptor arrays for the pending uploads; they point INTO `owned`, so they are freed
/// together with it and never outlive the parse they describe.
descriptors: []?Descriptors,
pending: std.ArrayList(DrawList.ModelUpload),
interface: Loader,

pub fn init(self: *ModelSource, gpa: std.mem.Allocator, asset_server: *AssetServer, models: *ModelTable) !void {
    var path_buffer: [entity.all_kinds.len][]const u8 = undefined;
    const model_paths = ModelTable.pathsByFileIndex(&path_buffer);
    std.debug.assert(model_paths.len <= contract.max_models);
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
        .owned = try gpa.alloc(?Parsed, model_paths.len),
        .descriptors = try gpa.alloc(?Descriptors, model_paths.len),
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
    @memset(self.descriptors, null);
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *ModelSource) void {
    for (self.owned, self.descriptors) |*slot, *described| self.release(slot, described);
    self.gpa.free(self.owned);
    self.gpa.free(self.descriptors);
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

fn release(self: *ModelSource, slot: *?Parsed, described: *?Descriptors) void {
    if (described.*) |desc| {
        for (desc.surfaces) |surfaces| self.gpa.free(surfaces);
        self.gpa.free(desc.surfaces);
        self.gpa.free(desc.meshes);
        self.gpa.free(desc.images);
        self.gpa.free(desc.samplers);
        described.* = null;
    }
    if (slot.*) |*parsed| {
        switch (parsed.*) {
            inline else => |*variant| variant.deinit(self.gpa),
        }
        slot.* = null;
    }
}

/// Build the contract's upload command out of whatever the parser produced. The big buffers
/// (vertices, indices, pixels) are referenced, not copied — only the descriptors allocate.
fn describe(self: *ModelSource, parsed: *const Parsed) !Descriptors {
    const gpa = self.gpa;
    return switch (parsed.*) {
        inline else => |data, tag| blk: {
            const samplers = try gpa.alloc(DrawList.SamplerUpload, data.samplers.len);
            errdefer gpa.free(samplers);
            for (data.samplers, samplers) |src, *dst| dst.* = .{ .mag_linear = src.mag_linear, .min_linear = src.min_linear };

            const images = try gpa.alloc(DrawList.ImageUpload, data.images.len);
            errdefer gpa.free(images);
            for (data.images, data.image_sampler, images) |src, sampler_index, *dst| {
                const width: u32 = @intCast(src.width);
                const height: u32 = @intCast(src.height);
                dst.* = .{
                    .width = width,
                    .height = height,
                    .pixels = src.pixels[0 .. width * height * 4],
                    .sampler_index = if (sampler_index) |value| @intCast(value) else null,
                };
            }

            const meshes = try gpa.alloc(DrawList.MeshUpload, data.meshes.len);
            errdefer gpa.free(meshes);
            const surfaces = try gpa.alloc([]DrawList.SurfaceUpload, data.meshes.len);
            errdefer gpa.free(surfaces);
            for (data.meshes, meshes, surfaces) |src, *dst, *surface_slice| {
                surface_slice.* = try gpa.alloc(DrawList.SurfaceUpload, src.surfaces.len);
                for (src.surfaces, surface_slice.*) |surface_src, *surface_dst| surface_dst.* = .{
                    .index_start = surface_src.index_start,
                    .index_count = surface_src.index_count,
                    .image_index = if (surface_src.image_index) |value| @intCast(value) else null,
                    .material_missing = surface_src.material_missing,
                };
                dst.* = .{
                    .name = src.name,
                    .vertices = std.mem.sliceAsBytes(src.vertices),
                    .skinned = tag == .skinned,
                    .indices = src.indices,
                    .surfaces = surface_slice.*,
                };
            }
            break :blk .{ .meshes = meshes, .surfaces = surfaces, .images = images, .samplers = samplers };
        },
    };
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

    var parsed: Parsed = if (model_spec.clip_names != null)
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, loader.io, file, kind_spec, model_spec) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, loader.io, file, kind_spec, model_spec) };

    // Replace the previous parse only once the new one is fully described, so a failure
    // here leaves the old model intact rather than half-freed.
    self.release(&self.owned[index], &self.descriptors[index]);
    self.owned[index] = parsed;
    self.descriptors[index] = self.describe(&self.owned[index].?) catch |err| {
        switch (parsed) {
            inline else => |*variant| variant.deinit(gpa),
        }
        self.owned[index] = null;
        return err;
    };
    const described = self.descriptors[index].?;

    const row: DrawList.ModelUpload = .{
        .index = @intCast(index),
        .meshes = described.meshes,
        .images = described.images,
        .samplers = described.samplers,
    };
    for (self.pending.items) |*upload| {
        if (upload.index != index) continue;
        upload.* = row;
        try self.models.reloaded.append(gpa, @intCast(index));
        return;
    }
    try self.pending.append(gpa, row);
    try self.models.reloaded.append(gpa, @intCast(index));
}

fn unload(loader: *Loader, index: usize) void {
    _ = loader;
    _ = index;
    // Parsed data stays owned until the next load replaces it; meshes, images and slots are
    // the backend's to release when it applies the next upload.
}
