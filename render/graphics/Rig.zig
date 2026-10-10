const Rig = @This();

const std = @import("std");
const shared = @import("shared");
const Model = @import("assets/root.zig").Model;
const ModelRow = @import("ModelRow.zig");

offset: shared.numz.Transform3D(f32),
loop_clips: std.EnumArray(shared.entity.Loop, ?usize),
action_clips: std.EnumArray(shared.entity.Action, ?usize),
look_nodes: []usize,
overlay_mask: ?[]bool,
spawn_duration: f32,
death_duration: f32,

pub const empty: Rig = .{
    .offset = .{},
    .loop_clips = .initFill(null),
    .action_clips = .initFill(null),
    .look_nodes = &.{},
    .overlay_mask = null,
    .spawn_duration = 0,
    .death_duration = 0,
};

pub fn init(
    self: *Rig,
    gpa: std.mem.Allocator,
    model: *const Model,
    row: *const ModelRow,
    kind_spec: *const shared.entity.Spec,
) !void {
    self.deinit(gpa);
    self.* = .empty;
    self.offset = row.offset;
    self.spawn_duration = kind_spec.spawn_duration;
    self.death_duration = kind_spec.death_duration;

    if (row.look_nodes) |look_node_names| {
        var found: [3]usize = undefined;
        var count: usize = 0;
        inline for (.{
            look_node_names.spine,
            look_node_names.neck,
            look_node_names.head,
        }) |maybe_node_name| {
            if (maybe_node_name) |node_name| {
                found[count] = model.nodeIndex(node_name) orelse return reportMissing(
                    model,
                    "look node",
                    node_name,
                    row,
                );
                count += 1;
            }
        }
        self.look_nodes = try gpa.dupe(usize, found[0..count]);
    }

    if (row.overlay_root) |root_name| {
        const overlay_root = model.nodeIndex(root_name) orelse return reportMissing(
            model,
            "overlay root",
            root_name,
            row,
        );
        const overlay_mask = try gpa.alloc(bool, model.nodes.items.len);
        for (model.nodes.items, overlay_mask, 0..) |node, *masked, node_index| {
            masked.* = node_index == overlay_root or if (node.parent) |parent| overlay_mask[parent] else false;
        }
        self.overlay_mask = overlay_mask;
    }

    for (std.enums.values(shared.entity.Loop)) |loop| {
        const clip_name = row.loop(loop) orelse continue;
        self.loop_clips.set(loop, model.clipIndex(clip_name) orelse return reportMissingClip(model, clip_name, row));
    }
    if (self.loop_clips.get(.death)) |index| {
        const death_clip = model.clips[index];
        self.death_duration = death_clip.end - death_clip.start;
    }
    for (std.enums.values(shared.entity.Action)) |action| {
        const clip_name = row.action(action) orelse continue;
        self.action_clips.set(action, model.clipIndex(clip_name) orelse return reportMissingClip(model, clip_name, row));
    }
}

pub fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
    gpa.free(self.look_nodes);
    if (self.overlay_mask) |overlay_mask| gpa.free(overlay_mask);
    self.* = .empty;
}

fn reportMissing(
    model: *const Model,
    what: []const u8,
    name: []const u8,
    row: *const ModelRow,
) error{NodeNotFound} {
    std.log.err("{s} \"{s}\" not found in {s}; nodes in this file:", .{ what, name, row.model });
    for (model.node_names) |node_name| std.log.err("  \"{s}\"", .{node_name});
    std.log.err("in assets/manifest (or the Zig spec) assign one of these", .{});
    return error.NodeNotFound;
}

fn reportMissingClip(
    model: *const Model,
    name: []const u8,
    row: *const ModelRow,
) error{ClipNotFound} {
    std.log.err("clip \"{s}\" not found in {s}; clips in this file:", .{ name, row.model });
    for (model.clips) |clip| std.log.err("  \"{s}\"", .{clip.name});
    std.log.err("in assets/manifest (or the Zig spec) assign null or one of these", .{});
    return error.ClipNotFound;
}
