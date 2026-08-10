//! What the loader hands the animator: one row per model the game knows about, the spec
//! read against that model's own names, and which rows just reloaded.
//!
//! Nothing about a file is in here. `Assets` fills it, `Animator` reads it, and the texture
//! slots the loader has to free live on `Assets` because only the loader ever frees one.

const ModelTable = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const Model = @import("assets").Model;
const Rig = @import("Rig.zig");

models: []Model,
/// One per model, same order. No .glb holds any of it — it is the entity spec read against
/// the file\'s own node names.
rigs: []Rig,
/// Rows whose file changed since the animator last looked. It drains this.
reloaded: std.ArrayList(u32),

pub fn init(gpa: std.mem.Allocator) !ModelTable {
    var buffer: [entity.all_kinds.len][]const u8 = undefined;
    const models = try gpa.alloc(Model, entity.modelPaths(&buffer).len);
    @memset(models, .empty);
    const rigs = try gpa.alloc(Rig, models.len);
    @memset(rigs, .empty);
    return .{ .models = models, .rigs = rigs, .reloaded = .empty };
}

pub fn deinit(self: *ModelTable, gpa: std.mem.Allocator) void {
    for (self.rigs) |*rig| rig.deinit(gpa);
    gpa.free(self.rigs);
    // Each row owns nodes, node names, clips, skins and surfaces. Freeing the array alone
    // leaks all of it — one allocation per node name, per clip, per skin.
    for (self.models) |*row| row.deinit(gpa);
    gpa.free(self.models);
    self.reloaded.deinit(gpa);
}

pub fn modelPtr(self: *const ModelTable, row: u32) *const Model {
    return &self.models[row];
}
