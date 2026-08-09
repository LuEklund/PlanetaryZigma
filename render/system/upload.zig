//! The glue: poll a watcher, ask `Assets` for the data, hand it to the renderer.
//!
//! Everything that knows BOTH sides lives here — which file list the game has, which slot a
//! texture belongs in, which clip a state plays. `Assets` knows none of it and the renderer
//! knows none of it, which is why neither depends on the other.

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const Assets = @import("Assets");
const Font = @import("shared").Font;
const Texture = @import("shared").Texture;
const Shader = @import("contract").Shader;
const ModelTable = @import("ModelTable.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque, "reload");

/// Data in, renderer out. Only what is worth sharing: the one-line calls belong at the
/// call site, where you can see what is being sent.

/// Images first, because a surface names the slot one of them landed in. The previous
/// upload's images are released here — the backend allocated them at our request.
pub fn model(
    gpa: std.mem.Allocator,
    renderer: *const RenderLib,
    table: *ModelTable,
    parsed_model: *Assets.Model,
    parsed: *const Assets.loader.Parsed,
    row: u32,
) !void {
    for (table.image_slots[row]) |slot| renderer.api.freeImage(renderer.handle, slot);
    gpa.free(table.image_slots[row]);
    table.image_slots[row] = &.{};

    try uploadModel(gpa, renderer, table, parsed_model, parsed, row);
    try table.reloaded.append(gpa, row);
}

/// Images first, because a surface names the slot one of them landed in.
fn uploadModel(
    gpa: std.mem.Allocator,
    renderer: *const RenderLib,
    table: *ModelTable,
    parsed_model: *Assets.Model,
    parsed: *const Assets.loader.Parsed,
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
            table.image_slots[row] = slots;

            const handles = try gpa.alloc(usize, data.meshes.len);
            errdefer gpa.free(handles);
            for (data.meshes, handles) |mesh, *handle| {
                const surfaces = try gpa.alloc(contract.SurfaceUpload, mesh.surfaces.len);
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

/// The primitives are assets like any other: generated here, uploaded through the same door.
pub fn generated(gpa: std.mem.Allocator, renderer: *const RenderLib, table: *ModelTable) !void {
    const surfaces = [_]contract.SurfaceUpload{.{
        .index_start = 0,
        .index_count = @intCast(Assets.box.indices.len),
        .texture_slot = @intCast(Texture.slot(.blank)),
    }};
    var buffer: [shared.entity.all_kinds.len][]const u8 = undefined;
    for (ModelTable.paths(&buffer), 0..) |path, row| {
        if (ModelTable.isFile(path)) continue;
        const handle = renderer.api.uploadMesh(renderer.handle, .none, &.{
            .name = path,
            .vertices = std.mem.sliceAsBytes(Assets.box.vertices),
            .skinned = false,
            .indices = Assets.box.indices,
            .surfaces = &surfaces,
        });
        const generated_model = &table.models[row];
        generated_model.mesh_handles = try gpa.alloc(usize, 1);
        generated_model.mesh_handles[0] = @intFromEnum(handle);
        try generated_model.surfaces.append(gpa, .{ .mesh_id = 0, .model_matrix = .identity });
    }
}
