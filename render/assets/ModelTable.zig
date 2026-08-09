const ModelTable = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const Model = @import("Model.zig");

/// Owned by the game loop, not render.so: animation reads clips and skins from here
/// without a pointer into a library that can be swapped underneath it.
models: []Model,
reloaded: std.ArrayList(u32),

/// A model that is generated rather than read: the row exists, it just has no file behind
/// it. Whoever generates the geometry fills the row in.
pub fn isFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".glb");
}

/// One row per distinct model path in the specs, in row order. Generated models are rows
/// like any other — a cube is an asset, not a special case in the renderer.
pub fn paths(buffer: *[entity.all_kinds.len][]const u8) []const []const u8 {
    var found: usize = 0;
    for (entity.all_kinds) |kind| {
        const model_spec = entity.spec(kind).model orelse continue;
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

pub fn handleForKind(kind: entity.Kind) ?u32 {
    const wanted = (entity.modelSpec(kind) orelse return null).path;
    var buffer: [entity.all_kinds.len][]const u8 = undefined;
    for (paths(&buffer), 0..) |path, index| {
        if (std.mem.eql(u8, path, wanted)) return @intCast(index);
    }
    return null;
}

pub fn modelPtr(self: *ModelTable, handle: u32) *Model {
    return &self.models[handle];
}
