const std = @import("std");
const shared = @import("shared");
const contract = @import("renderer_contract");

pub fn update(planet: *shared.Planet, api: *const contract.Api, handle: *anyopaque) void {
    for (planet.removes.items) |removed| {
        if (removed.mesh_handle == 0) continue;
        api.freeMesh(handle, @enumFromInt(removed.mesh_handle));
    }
    for (planet.uploads.items) |chunk_upload| {
        const entry = planet.chunks.getPtr(chunk_upload.coord) orelse continue;
        const index_count: u32 = @intCast(chunk_upload.indices.len);
        const all_surfaces = [_]contract.SurfaceUpload{ .{
            .index_start = 0,
            .index_count = chunk_upload.opaque_index_count,
            .transparent = false,
            .texture = .blank,
        }, .{
            .index_start = chunk_upload.opaque_index_count,
            .index_count = index_count - chunk_upload.opaque_index_count,
            .transparent = true,
            .texture = .blank,
        } };
        const surfaces = if (index_count == chunk_upload.opaque_index_count) all_surfaces[0..1] else all_surfaces[0..];
        entry.mesh_handle = @intFromEnum(api.uploadMesh(handle, @enumFromInt(entry.mesh_handle), &.{
            .name = "chunk",
            .vertices = std.mem.sliceAsBytes(chunk_upload.vertices),
            .skinned = false,
            .indices = chunk_upload.indices,
            .surfaces = surfaces,
        }));
    }
}
