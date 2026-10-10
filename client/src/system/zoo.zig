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
    spinning: bool = true,
    /// Thumbnail mode: only the selected subject, no UI, no outline.
    photo: bool = false,
    planet_radius: u32 = 150,
};

pub const Command = union(enum) {
    none,
    exit,
    select_kind: u16,
    select_slot: Slot,
    assign_clip: ?u16,
    play_action,
    toggle_spin,
    focus,
    toggle_photo,
    set_radius: u32,
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

const first_id: u32 = 2;
const subject_height: f32 = 1;
const spin_speed: f32 = 0.6;
const grid_columns: usize = 6;
const grid_spacing: f32 = 7;
const camera_pitch: f32 = -0.55;
const camera_back: f32 = 40;

fn subjectId(index: usize) shared.entity.Id {
    return @enumFromInt(first_id + index);
}

fn gridUp(index: usize, planet_radius: u32) nz.Vec3(f32) {
    const rows = (kinds.len + grid_columns - 1) / grid_columns;
    const column: f32 = @floatFromInt(index % grid_columns);
    const row: f32 = @floatFromInt(index / grid_columns);
    const x = (column - @as(f32, @floatFromInt(grid_columns - 1)) / 2) * grid_spacing;
    const z = (row - @as(f32, @floatFromInt(rows - 1)) / 2) * grid_spacing;
    return nz.vec.normalize(nz.Vec3(f32){ x, @floatFromInt(planet_radius), z });
}

pub fn populate(world: *World, gpa: std.mem.Allocator, state: *const State) !void {
    try world.planet.sync(gpa, state.planet_radius);
    for (0..kinds.len) |index| {
        if (state.photo and index != state.kind_index) continue;
        try spawn(world, index, gridUp(index, state.planet_radius));
    }
    const top = surfaceRadius(world, .{ 0, 1, 0 }) + subject_height;
    world.controller.free_camera = true;
    world.camera.free_speed = 12;
    world.camera.pitch = camera_pitch;
    world.camera.yaw_rotation = .identity;
    world.camera.transform = .{ .position = .{
        0,
        top - camera_back * @sin(camera_pitch),
        camera_back * @cos(camera_pitch),
    } };
}

fn spawn(world: *World, index: usize, up: nz.Vec3(f32)) !void {
    try world.applySpawn(.{
        .id = subjectId(index),
        .kind = kinds[index],
        .position = nz.vec.scale(up, surfaceRadius(world, up) + subject_height),
        .rotation = nz.Quat(f32).identity.toVec(),
        .data = .none,
    });
}

/// Spins the subjects; only the selected one plays the selected loop.
pub fn update(world: *World, state: *State) void {
    if (state.spinning) state.yaw += spin_speed * world.delta_time;
    const selected_loop: shared.entity.Loop = switch (state.slot) {
        .loop => |loop| loop,
        .action => .idle,
    };
    for (0..kinds.len) |index| {
        const subject = world.getPtr(subjectId(index)) orelse continue;
        const up = gridUp(index, state.planet_radius);
        subject.motion.update = null;
        subject.transform.rotation = shared.math.rotationFromUp(up).mul(
            nz.Quat(f32).angleAxis(state.yaw, .{ 0, 1, 0 }),
        );
        subject.override_animation_loop = if (index == state.kind_index) selected_loop else .idle;
    }
}

/// Puts the free camera in front of the selected subject, far enough for its size.
pub fn focus(world: *World, state: *State) void {
    state.spinning = false;
    state.yaw = 0;
    const subject = world.getPtr(subjectId(state.kind_index)) orelse return;
    const up = nz.vec.normalize(subject.transform.position);
    const forward = nz.vec.normalize(shared.math.projectOnPlane(.{ 0, 0, -1 }, up));
    const size: f32 = switch ((kinds[state.kind_index].collider() orelse return).shape) {
        .capsule => |capsule| capsule.half_height + capsule.radius,
        .box => |box| @max(box.x, @max(box.y, box.z)),
    };
    const distance = @max(3.5, size * 4.5);
    world.camera.transform.position = subject.transform.position + nz.vec.scale(forward, distance) + nz.vec.scale(up, distance * 0.35);
    world.camera.yaw_rotation = .lookAt(nz.vec.scale(forward, -1), up);
    world.camera.pitch = -0.3;
}

pub fn selectedId(state: *const State) shared.entity.Id {
    return subjectId(state.kind_index);
}

fn surfaceRadius(world: *const World, up: nz.Vec3(f32)) f32 {
    return nz.vec.length(world.planet.surfacePoint(up));
}

pub fn labels(world: *World, state: *const State, out: []Label) []Label {
    const count = kinds.len;
    var len: usize = 0;
    for (0..count) |index| {
        const subject = world.getPtr(subjectId(index)) orelse continue;
        out[len] = .{
            .index = @intCast(index),
            .name = ModelRow.kindName(kinds[index]),
            .position = subject.transform.position,
            .selected = index == state.kind_index,
        };
        len += 1;
    }
    return out[0..len];
}

pub const Label = struct { index: u16, name: []const u8, position: nz.Vec3(f32), selected: bool };
pub const max_labels = kinds.len;

/// Console form of the zoo panel:
/// `kind <name>`, `slot <loop|action>`, `clip <name|none>`, `play`, `spin`, `focus`, `photo`, `radius <n>`, `exit`.
pub fn parseCommand(line: []const u8, models: *const Models, state: *const State) Command {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = words.next() orelse return .none;
    const argument = words.rest();
    if (std.mem.eql(u8, verb, "exit")) return .exit;
    if (std.mem.eql(u8, verb, "play")) return .play_action;
    if (std.mem.eql(u8, verb, "spin")) return .toggle_spin;
    if (std.mem.eql(u8, verb, "focus")) return .focus;
    if (std.mem.eql(u8, verb, "photo")) return .toggle_photo;
    if (std.mem.eql(u8, verb, "radius")) {
        const radius = std.fmt.parseInt(u32, argument, 10) catch return .none;
        return .{ .set_radius = radius };
    }
    if (std.mem.eql(u8, verb, "kind")) {
        for (kinds, 0..) |kind, index| {
            if (std.mem.eql(
                u8,
                ModelRow.kindName(kind),
                argument,
            )) return .{ .select_kind = @intCast(index) };
        }
    } else if (std.mem.eql(u8, verb, "slot")) {
        if (std.meta.stringToEnum(shared.entity.Loop, argument)) |loop| return .{
            .select_slot = .{ .loop = loop },
        };
        if (std.meta.stringToEnum(shared.entity.Action, argument)) |action| return .{
            .select_slot = .{ .action = action },
        };
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

pub fn subjectAnimation(world: *World, state: *const State) graphics.Animator.Handle {
    const subject = world.getPtr(subjectId(state.kind_index)) orelse return .none;
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
    const clip_name: ?[]const u8 = if (clip) |index| models.modelPtr(
        handle,
    ).clips[index].name else null;
    switch (slot) {
        .loop => |loop| row.setLoop(loop, clip_name),
        .action => |action| row.setAction(action, clip_name),
    }
    try row.save(io, models.dir, kind);
}
