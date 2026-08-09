//! What the game wants from a parsed model: which clip plays in which state, which nodes
//! follow the camera, which nodes the overlay reaches, how long spawning and dying take.
//!
//! None of it is in the .glb — it is the entity spec read against the file's own names. So
//! it is built here, once at load, rather than inside the parser.

const Rig = @This();

const std = @import("std");
const shared = @import("shared");
const Model = @import("Assets").Model;

state_clips: std.EnumArray(shared.entity.State, ?usize),
look_nodes: []usize,
overlay_mask: ?[]bool,
spawn_duration: f32,
death_duration: f32,

pub const empty: Rig = .{
    .state_clips = .initFill(null),
    .look_nodes = &.{},
    .overlay_mask = null,
    .spawn_duration = 0,
    .death_duration = 0,
};

pub fn init(
    self: *Rig,
    gpa: std.mem.Allocator,
    model: *const Model,
    kind_spec: shared.entity.Spec,
    spec: shared.entity.ModelSpec,
) !void {
    self.deinit(gpa);
    self.* = .empty;
    self.spawn_duration = kind_spec.spawn_duration;
    self.death_duration = kind_spec.death_duration;

    if (spec.look_node_names) |look_node_names| {
        var found: [3]usize = undefined;
        var count: usize = 0;
        inline for (.{ look_node_names.spine, look_node_names.neck, look_node_names.head }) |maybe_node_name| {
            if (maybe_node_name) |node_name| {
                found[count] = model.nodeIndex(node_name) orelse return reportMissing(model, "look node", node_name, spec);
                count += 1;
            }
        }
        self.look_nodes = try gpa.dupe(usize, found[0..count]);
    }

    if (spec.overlay_root_name) |root_name| {
        const overlay_root = model.nodeIndex(root_name) orelse return reportMissing(model, "overlay root", root_name, spec);
        const overlay_mask = try gpa.alloc(bool, model.nodes.items.len);
        for (model.nodes.items, overlay_mask, 0..) |node, *masked, node_index| {
            masked.* = node_index == overlay_root or if (node.parent) |parent| overlay_mask[parent] else false;
        }
        self.overlay_mask = overlay_mask;
    }

    if (spec.clip_names) |clip_names| {
        for (clip_names.values, &self.state_clips.values) |maybe_name, *state_clip| {
            state_clip.* = if (maybe_name) |clip_name| model.clipIndex(clip_name) orelse
                return reportMissingClip(model, clip_name, spec) else null;
        }
        // The death animation's own length beats whatever the spec guessed.
        if (self.state_clips.get(.death)) |index| {
            const death_clip = model.clips[index];
            self.death_duration = death_clip.end - death_clip.start;
        }
    }
}

pub fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
    gpa.free(self.look_nodes);
    if (self.overlay_mask) |overlay_mask| gpa.free(overlay_mask);
    self.* = .empty;
}

fn reportMissing(model: *const Model, what: []const u8, name: []const u8, spec: shared.entity.ModelSpec) error{NodeNotFound} {
    std.log.err("{s} \"{s}\" not found in {s}; nodes in this file:", .{ what, name, spec.path });
    for (model.node_names) |node_name| std.log.err("  \"{s}\"", .{node_name});
    std.log.err("in the model spec (shared/entity.zig) assign one of these", .{});
    return error.NodeNotFound;
}

fn reportMissingClip(model: *const Model, name: []const u8, spec: shared.entity.ModelSpec) error{ClipNotFound} {
    std.log.err("clip \"{s}\" not found in {s}; clips in this file:", .{ name, spec.path });
    for (model.clips) |clip| std.log.err("  \"{s}\"", .{clip.name});
    std.log.err("in the model spec assign null or one of these", .{});
    return error.ClipNotFound;
}
