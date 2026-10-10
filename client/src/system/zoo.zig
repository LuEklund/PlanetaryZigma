const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const graphics = @import("graphics");
const World = @import("../World.zig");
const Kind = shared.entity.Kind;
const ModelRow = graphics.ModelRow;
const Models = graphics.Assets.Models;

pub const Slot = union(enum) {
    loop: shared.entity.Loop,
    action: shared.entity.Action,
};

pub const State = struct {
    kind_index: u16 = 0,
    slot: Slot = .{ .loop = .idle },
    yaw: f32 = 0,
    distance: f32 = 6,
};

pub const Command = union(enum) {
    none,
    exit,
    select_kind: u16,
    select_slot: Slot,
    assign_clip: ?u16,
    play_action,
};

pub const kinds: []const Kind = &kinds_array;
const kinds_array = blk: {
    var count: usize = 0;
    for (shared.entity.all_kinds) |kind| {
        if (kind.modelSpec() != null) count += 1;
    }
    var list: [count]Kind = undefined;
    var index: usize = 0;
    for (shared.entity.all_kinds) |kind| {
        if (kind.modelSpec() == null) continue;
        list[index] = kind;
        index += 1;
    }
    break :blk list;
};

const subject_id: shared.entity.Id = @enumFromInt(2);
const planet_radius: f32 = 18;
const subject_height: f32 = 1;
const spin_speed: f32 = 0.6;

pub fn populate(world: *World, gpa: std.mem.Allocator, state: *const State) !void {
    world.controller.free_camera = false;
    try world.planet.sync(gpa, planet_radius);
    try world.applySpawn(.{
        .id = subject_id,
        .kind = kinds[state.kind_index],
        .position = .{ 0, planet_radius + subject_height, 0 },
        .rotation = nz.Quat(f32).identity.toVec(),
        .data = .none,
    });
}

pub fn update(world: *World, state: *State, wheel: f64) void {
    state.yaw += spin_speed * world.delta_time;
    state.distance = std.math.clamp(state.distance * std.math.pow(f32, 0.9, @floatCast(wheel)), 1.5, 80);
    world.camera.transform = .{ .position = .{ 0, planet_radius + subject_height + state.distance * 0.2, state.distance } };
    const subject = world.getPtr(subject_id) orelse return;
    subject.motion.update = null;
    subject.transform.rotation = nz.Quat(f32).angleAxis(state.yaw, .{ 0, 1, 0 });
    subject.override_animation_loop = switch (state.slot) {
        .loop => |loop| loop,
        .action => .idle,
    };
}

/// Console form of the zoo panel: `kind <name>`, `slot <loop|action name>`, `clip <name|none>`, `play`, `exit`.
pub fn parseCommand(line: []const u8, models: *const Models, state: *const State) Command {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = words.next() orelse return .none;
    const argument = words.rest();
    if (std.mem.eql(u8, verb, "exit")) return .exit;
    if (std.mem.eql(u8, verb, "play")) return .play_action;
    if (std.mem.eql(u8, verb, "kind")) {
        for (kinds, 0..) |kind, index| {
            if (std.mem.eql(u8, ModelRow.kindName(kind), argument)) return .{ .select_kind = @intCast(index) };
        }
    } else if (std.mem.eql(u8, verb, "slot")) {
        if (std.meta.stringToEnum(shared.entity.Loop, argument)) |loop| return .{ .select_slot = .{ .loop = loop } };
        if (std.meta.stringToEnum(shared.entity.Action, argument)) |action| return .{ .select_slot = .{ .action = action } };
    } else if (std.mem.eql(u8, verb, "clip")) {
        if (std.mem.eql(u8, argument, "none")) return .{ .assign_clip = null };
        const clips = models.modelPtr(models.get(kinds[state.kind_index])).clips;
        for (clips, 0..) |clip, index| {
            if (std.mem.eql(u8, clip.name, argument)) return .{ .assign_clip = @intCast(index) };
        }
    }
    std.log.warn("zoo: unknown command \"{s}\"", .{line});
    return .none;
}

pub fn subjectAnimation(world: *World) graphics.Animator.Handle {
    const subject = world.getPtr(subject_id) orelse return .none;
    return subject.animation;
}

pub fn slotClip(row: *const ModelRow, slot: Slot) ?[]const u8 {
    return switch (slot) {
        .loop => |loop| row.loop(loop),
        .action => |action| row.action(action),
    };
}

/// Writes the kind's manifest with one slot changed; the asset watcher applies it next frame.
pub fn assign(io: std.Io, models: *const Models, kind: Kind, slot: Slot, clip: ?u16) !void {
    const handle = models.get(kind);
    var row = models.row(handle) orelse return;
    const clip_name: ?[]const u8 = if (clip) |index| models.modelPtr(handle).clips[index].name else null;
    switch (slot) {
        .loop => |loop| row.setLoop(loop, clip_name),
        .action => |action| row.setAction(action, clip_name),
    }
    try row.save(io, models.dir, kind);
}
