const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");

/// The GPU side of chunk streaming: `Planet.update` decides which chunks appear and vanish,
/// this hands the meshes to the renderer and stores the handles back on the chunk entries.
pub fn update(planet: *shared.Planet, api: *const contract.Api, handle: *anyopaque) void {
    for (planet.removes.items) |removed| {
        if (removed.mesh_handle == 0) continue;
        api.freeMesh(handle, @enumFromInt(removed.mesh_handle));
    }
    for (planet.uploads.items) |chunk_upload| {
        const entry = planet.chunks.getPtr(chunk_upload.coord) orelse continue;
        const surfaces = [_]contract.SurfaceUpload{.{
            .index_start = 0,
            .index_count = @intCast(chunk_upload.indices.len),
            .transparent = false,
            .texture = .blank,
        }};
        entry.mesh_handle = @intFromEnum(api.uploadMesh(handle, @enumFromInt(entry.mesh_handle), &.{
            .name = "chunk",
            .vertices = std.mem.sliceAsBytes(chunk_upload.vertices),
            .skinned = false,
            .indices = chunk_upload.indices,
            .surfaces = &surfaces,
        }));
    }
}
