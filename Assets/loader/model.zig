const std = @import("std");
const shared = @import("shared");
const Assets = @import("../Watcher.zig");
const Model = @import("../types/Model.zig");
const gltf = @import("../types/gltf.zig");

/// What came out of the file and still has to reach a GPU: vertices, indices, and any
/// images the glb embedded. The CPU half went straight into the `Model`.
pub const Parsed = union(enum) {
    static: gltf.UploadData(shared.StaticVertex),
    skinned: gltf.UploadData(shared.SkinnedVertex),

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*variant| variant.deinit(gpa),
        }
    }
};

/// `skinned` picks the vertex layout to produce. The file decides whether it HAS skins;
/// the caller decides which layout it wants the vertices in.
pub fn parse(gpa: std.mem.Allocator, watcher: *Assets, io: std.Io, entry: u32, model: *Model, skinned: bool) !Parsed {
    const file = try watcher.open(io, entry);
    defer file.close(io);

    if (!model.isEmpty()) model.deinit(gpa);
    model.* = .empty;

    return if (skinned)
        .{ .skinned = try model.parseGlb(shared.SkinnedVertex, gpa, io, file) }
    else
        .{ .static = try model.parseGlb(shared.StaticVertex, gpa, io, file) };
}
