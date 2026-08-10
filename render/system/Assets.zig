//! Everything the game has on disk and what it turned into: four watchers, the fonts they
//! baked, the models they parsed.
//!
//! The renderer arrives as a parameter and is never stored, so nothing here holds a pointer
//! into a library that can be swapped underneath it. `assets` knows nothing about a renderer
//! and the renderer knows nothing about a file — this is the one place that knows both, and
//! it is a struct that owns state rather than a system anyone talks to.

const Assets = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const assets = @import("assets");
const ModelTable = @import("ModelTable.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

shader_files: assets.Watcher,
texture_files: assets.Watcher,
font_files: assets.Watcher,
model_files: assets.Watcher,
models: ModelTable,
fonts: [shared.Font.count]shared.Font,
/// Texture slots the backend handed back for each model's embedded images. Ours to free on
/// a reload, and nobody else's business — the animator never sees one.
image_slots: [][]u32,

/// One watcher per kind, so a poll has exactly one thing to do with every row it returns.
/// Rows line up with the model table's: a generated model is registered like any other and
/// simply never stats, so nothing has to renumber around it.
pub fn init(gpa: std.mem.Allocator, io: std.Io) !Assets {
    var self: Assets = .{
        .shader_files = try .init(gpa, io, "shaders"),
        .texture_files = try .init(gpa, io, "textures"),
        .font_files = try .init(gpa, io, "fonts"),
        .model_files = try .init(gpa, io, "objects"),
        .models = try .init(gpa),
        .fonts = @splat(.empty),
        .image_slots = &.{},
    };
    errdefer self.deinit(gpa, io);

    self.image_slots = try gpa.alloc([]u32, self.models.models.len);
    @memset(self.image_slots, &.{});

    // Registered in enum order, so a watcher row IS the shader kind it belongs to.
    for (std.enums.values(contract.Shader.Kind)) |kind| try self.shader_files.add(contract.Shader.get(kind).path);

    var texture_paths: [shared.Texture.paths_capacity][]const u8 = undefined;
    for (shared.Texture.paths(&texture_paths)) |path| try self.texture_files.add(path);

    for (shared.Font.files) |path| try self.font_files.add(path);

    var model_paths: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (shared.entity.modelPaths(&model_paths)) |path| {
        try self.model_files.add(if (std.mem.startsWith(u8, path, "objects/")) path["objects/".len..] else path);
    }
    return self;
}

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, io: std.Io) void {
    self.shader_files.deinit(io);
    self.texture_files.deinit(io);
    self.font_files.deinit(io);
    self.model_files.deinit(io);
    self.models.deinit(gpa);
    for (self.image_slots) |slots| gpa.free(slots);
    gpa.free(self.image_slots);
}

/// Everything that changed on disk: read, parsed, pushed at the renderer. Four loops and
/// no switch — each watcher feeds exactly one kind of upload. The first poll reports every
/// file, so loading and reloading are one code path.
pub fn uploadChanged(self: *Assets, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    // Shaders first: nothing can draw without them, and a .spv needs no parse at all.
    for (self.shader_files.poll(io)) |row| {
        const path = self.shader_files.path(row);
        const spirv = try assets.read(gpa, io, self.shader_files.handle, path);
        defer gpa.free(spirv);
        renderer.api.uploadShader(renderer.handle, row, spirv.ptr, spirv.len);
    }

    for (self.texture_files.poll(io)) |row| {
        const path = self.texture_files.path(row);
        const bytes = try assets.read(gpa, io, self.texture_files.handle, path);
        defer gpa.free(bytes);

        const slot = shared.Texture.reserved + row;
        // A file that will not decode binds the fallback rather than failing the frame: an
        // empty face list is what the backend reads as "use missing".
        var decoded = assets.parse.texture(gpa, bytes, slot == shared.Texture.slot(.skybox_cubemap)) catch |err| {
            std.log.warn("texture {s}: {t} - binding the fallback", .{ path, err });
            renderer.api.uploadTexture(renderer.handle, &.{ .slot = slot, .width = 0, .height = 0, .faces = &.{} });
            continue;
        };
        defer decoded.deinit(gpa);
        renderer.api.uploadTexture(renderer.handle, &.{
            .slot = slot,
            .width = decoded.width,
            .height = decoded.height,
            .faces = decoded.faces,
        });
    }

    for (self.font_files.poll(io)) |row| {
        const path = self.font_files.path(row);
        const bytes = try assets.read(gpa, io, self.font_files.handle, path);
        defer gpa.free(bytes);

        // Glyph metrics land in our row; only the atlas is the renderer's business.
        const baked = &self.fonts[row];
        const coverage = try assets.parse.font(baked, gpa, bytes);
        defer gpa.free(coverage);

        if (baked.atlas_texture_index != 0) renderer.api.freeImage(renderer.handle, baked.atlas_texture_index);
        baked.atlas_texture_index = renderer.api.uploadImage(renderer.handle, &.{
            .width = shared.Font.atlas_width,
            .height = shared.Font.atlas_height,
            .pixels = coverage,
            .r8 = true,
            .mips = false,
            .mag_linear = true,
            .min_linear = true,
        });
    }

    for (self.model_files.poll(io)) |row| {
        const path = self.model_files.path(row);
        const kind_spec = shared.entity.spec(shared.entity.kindForModelRow(row));
        const model_spec = kind_spec.model orelse continue;
        const bytes = try assets.read(gpa, io, self.model_files.handle, path);
        defer gpa.free(bytes);

        const model = &self.models.models[row];

        // Everything the last load put on the GPU goes first, and it has to go BEFORE the
        // parse: that resets the row, and the mesh handles are the only record of what to
        // free. The row names new ones a few lines down.
        for (model.mesh_handles) |mesh| {
            if (mesh != 0) renderer.api.freeMesh(renderer.handle, @enumFromInt(mesh));
        }
        for (self.image_slots[row]) |slot| renderer.api.freeImage(renderer.handle, slot);
        gpa.free(self.image_slots[row]);
        self.image_slots[row] = &.{};

        var parsed = try assets.parse.model(gpa, bytes, model, model_spec.clip_names != null);
        defer parsed.deinit(gpa);
        try self.models.rigs[row].init(gpa, model, kind_spec, model_spec);

        try self.uploadMeshes(gpa, renderer, model, &parsed, row);
        try self.models.reloaded.append(gpa, row);
    }
}

/// A model with no file behind it is never polled, so its one box mesh is uploaded here —
/// at start, and again after a render swap, because the old handles went with the image.
pub fn uploadPrimitives(self: *Assets, gpa: std.mem.Allocator, renderer: *const RenderLib) !void {
    const surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(assets.box.indices.len),
        .texture_slot = @intCast(shared.Texture.slot(.blank)),
    }};
    var buffer: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (shared.entity.modelPaths(&buffer), 0..) |path, row| {
        if (shared.entity.isModelFile(path)) continue;
        const handle = renderer.api.uploadMesh(renderer.handle, .none, &.{
            .name = path,
            .vertices = std.mem.sliceAsBytes(assets.box.vertices),
            .skinned = false,
            .indices = assets.box.indices,
            .surfaces = &surfaces,
        });
        const model = &self.models.models[row];
        gpa.free(model.mesh_handles);
        model.mesh_handles = try gpa.alloc(usize, 1);
        model.mesh_handles[0] = @intFromEnum(handle);
        model.surfaces.clearRetainingCapacity();
        try model.surfaces.append(gpa, .{ .mesh_id = 0, .model_matrix = .identity });
    }
}

/// Images first, because a surface names the slot one of them landed in.
fn uploadMeshes(
    self: *Assets,
    gpa: std.mem.Allocator,
    renderer: *const RenderLib,
    parsed_model: *assets.Model,
    parsed: *const assets.parse.Parsed,
    row: u32,
) !void {
    switch (parsed.*) {
        inline else => |*data, tag| {
            const slots = try gpa.alloc(u32, data.images.len);
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
            self.image_slots[row] = slots;

            const handles = try gpa.alloc(usize, data.meshes.len);
            errdefer gpa.free(handles);
            for (data.meshes, handles) |mesh, *handle| {
                const surfaces = try gpa.alloc(contract.SurfaceUpload, mesh.surfaces.len);
                defer gpa.free(surfaces);
                for (mesh.surfaces, surfaces) |src, *surface| surface.* = .{
                    .index_start = src.index_start,
                    .index_count = src.index_count,
                    .texture_slot = @intCast(if (src.material_missing)
                        shared.Texture.slot(.missing)
                    else if (src.image_index) |image_index|
                        slots[image_index]
                    else
                        shared.Texture.slot(.blank)),
                };
                handle.* = @intFromEnum(renderer.api.uploadMesh(renderer.handle, .none, &.{
                    .name = mesh.name,
                    .vertices = std.mem.sliceAsBytes(mesh.vertices),
                    .skinned = tag == .skinned,
                    .indices = mesh.indices,
                    .surfaces = surfaces,
                }));
            }
            parsed_model.mesh_handles = handles;
        },
    }
}
