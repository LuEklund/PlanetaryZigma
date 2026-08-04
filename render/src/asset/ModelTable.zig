const ModelTable = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const Model = @import("Model.zig");

/// CPU-side model data, owned by whoever runs the game loop rather than by the renderer.
/// The renderer's loader parses into this and keeps only the GPU half (meshes, image
/// slots), so animation code reads clips and skins without reaching into render.so.
models: []Model,
reloaded: std.ArrayList(u32),

/// Every distinct .glb path, in the order kinds declare them. This ordering IS the file
/// index, and the loader builds its own file list from the same call, so the two cannot
/// disagree.
pub fn paths(buffer: *[entity.all_kinds.len][]const u8) []const []const u8 {
    var found: usize = 0;
    for (entity.all_kinds) |kind| {
        const model_spec = entity.spec(kind).model orelse continue;
        if (!std.mem.endsWith(u8, model_spec.path, ".glb")) continue;
        for (buffer[0..found]) |seen| {
            if (std.mem.eql(u8, seen, model_spec.path)) break;
        } else {
            buffer[found] = model_spec.path;
            found += 1;
        }
    }
    return buffer[0..found];
}

pub fn init(gpa: std.mem.Allocator) !ModelTable {
    var buffer: [entity.all_kinds.len][]const u8 = undefined;
    const models = try gpa.alloc(Model, paths(&buffer).len);
    @memset(models, .empty);
    return .{ .models = models, .reloaded = .empty };
}

pub fn deinit(self: *ModelTable, gpa: std.mem.Allocator) void {
    gpa.free(self.models);
    self.reloaded.deinit(gpa);
}

pub fn handleForKind(kind: entity.Kind) ?Model.Handle {
    const wanted = (entity.modelSpec(kind) orelse return null).path;
    if (!std.mem.endsWith(u8, wanted, ".glb")) {
        return .{ .generated = std.meta.stringToEnum(Model.Generated, wanted).? };
    }
    var buffer: [entity.all_kinds.len][]const u8 = undefined;
    for (paths(&buffer), 0..) |path, index| {
        if (std.mem.eql(u8, path, wanted)) return .{ .file = @intCast(index) };
    }
    return null;
}

pub fn modelPtr(self: *ModelTable, handle: Model.Handle) ?*Model {
    return switch (handle) {
        .file => |file_index| &self.models[file_index],
        .generated => null,
    };
}
