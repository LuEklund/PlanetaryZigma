//! Parses glTF on THIS side of the boundary. Twin of ShaderSource/TextureSource/FontSource.
//!
//! The CPU `Model` (nodes, skins, clips) is written straight into the caller-owned
//! `ModelTable`, which already lives above the boundary. Geometry and embedded images go
//! over one at a time and come back as handles, which land in `Model.mesh_handles`.

const ModelSource = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const AssetServer = @import("assets").AssetServer;
const render = @import("contract");
const ModelTable = @import("assets").ModelTable;
const Model = @import("assets").Model;
const Texture = @import("shared").Texture;

const Loader = AssetServer.Loader;
const gltf = @import("assets").gltf;

/// glTF keeps its own generic shape; the contract does not name it. This is the adapter.
const Parsed = union(enum) {
    static: gltf.UploadData(shared.StaticVertex),
    skinned: gltf.UploadData(shared.SkinnedVertex),
};

gpa: std.mem.Allocator,
models: *ModelTable,
kinds: []entity.Kind,
/// Texture slots the backend handed back for this model's embedded images. Ours to free
/// on a reload, because the backend allocated them at our request.
image_slots: [][]u32,
renderer: *const render.Renderer,
interface: Loader,

pub fn init(
    self: *ModelSource,
    gpa: std.mem.Allocator,
    asset_server: *AssetServer,
    models: *ModelTable,
    renderer: *const render.Renderer,
) !void {
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
        .image_slots = try gpa.alloc([]u32, model_paths.len),
        .renderer = renderer,
        .interface = .{
            .gpa = gpa,
            .io = asset_server.io,
            .root_path = "objects",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
    @memset(self.image_slots, &.{});
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *ModelSource) void {
    for (0..self.image_slots.len) |index| self.releaseImages(index);
    self.gpa.free(self.image_slots);
    self.gpa.free(self.kinds);
    self.gpa.free(self.interface.files);
}

fn releaseImages(self: *ModelSource, index: usize) void {
    for (self.image_slots[index]) |slot| self.renderer.vtable.freeImage(self.renderer.userdata, slot);
    self.gpa.free(self.image_slots[index]);
    self.image_slots[index] = &.{};
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
    defer switch (parsed) {
        inline else => |*variant| variant.deinit(gpa),
    };

    self.releaseImages(index);
    try self.upload(index, model, &parsed);
    try self.models.reloaded.append(gpa, @intCast(index));
}

/// Images first, because a surface names the slot one of them landed in.
fn upload(self: *ModelSource, index: usize, model: *Model, parsed: *const Parsed) !void {
    const gpa = self.gpa;
    const renderer = self.renderer;

    switch (parsed.*) {
        inline else => |*data, tag| {
            const slots = try gpa.alloc(u32, data.images.len);
            errdefer gpa.free(slots);
            for (data.images, data.image_sampler, slots) |image, sampler_index, *slot| {
                const sampler = if (sampler_index) |sampler| data.samplers[sampler] else null;
                const width: u32 = @intCast(image.width);
                const height: u32 = @intCast(image.height);
                slot.* = renderer.vtable.uploadImage(renderer.userdata, &.{
                    .width = width,
                    .height = height,
                    .pixels = image.pixels[0 .. width * height * 4],
                    .r8 = false,
                    .mips = true,
                    .mag_linear = if (sampler) |desc| desc.mag_linear else true,
                    .min_linear = if (sampler) |desc| desc.min_linear else true,
                });
            }
            self.image_slots[index] = slots;

            const handles = try gpa.alloc(usize, data.meshes.len);
            errdefer gpa.free(handles);
            for (data.meshes, handles) |mesh, *handle| {
                const surfaces = try gpa.alloc(render.SurfaceUpload, mesh.surfaces.len);
                defer gpa.free(surfaces);
                for (mesh.surfaces, surfaces) |src, *surface| surface.* = .{
                    .index_start = src.index_start,
                    .index_count = src.index_count,
                    .texture_slot = @intCast(if (src.material_missing)
                        Texture.slot(.missing)
                    else if (src.image_index) |image_index|
                        slots[image_index]
                    else
                        Texture.slot(.blank)),
                };
                handle.* = @intFromEnum(renderer.vtable.uploadMesh(renderer.userdata, .none, &.{
                    .name = mesh.name,
                    .vertices = std.mem.sliceAsBytes(mesh.vertices),
                    .skinned = tag == .skinned,
                    .indices = mesh.indices,
                    .surfaces = surfaces,
                }));
            }
            model.mesh_handles = handles;
        },
    }
}

fn unload(loader: *Loader, index: usize) void {
    _ = loader;
    _ = index;
    // Parsed data stays owned until the next load replaces it; meshes, images and slots are
    // the backend's to release when it applies the next upload.
}
