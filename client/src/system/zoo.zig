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
    grid: bool = false,
    planet_radius: u32 = 150,
};

pub const Command = union(enum) {
    none,
    exit,
    select_kind: u16,
    select_slot: Slot,
    assign_clip: ?u16,
    play_action,
    toggle_grid,
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
const grid_pitch: f32 = -0.55;

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
    world.controller.free_camera = false;
    try world.planet.sync(gpa, state.planet_radius);
    if (!state.grid) return spawn(world, 0, state.kind_index, .{ 0, 1, 0 });
    for (0..kinds.len) |index| try spawn(world, index, index, gridUp(index, state.planet_radius));
}

fn spawn(world: *World, slot: usize, kind_index: usize, up: nz.Vec3(f32)) !void {
    try world.applySpawn(.{
        .id = subjectId(slot),
        .kind = kinds[kind_index],
        .position = nz.vec.scale(up, surfaceRadius(world, up) + subject_height),
        .rotation = nz.Quat(f32).identity.toVec(),
        .data = .none,
    });
}

pub fn update(world: *World, state: *State, wheel: f64) void {
    state.yaw += spin_speed * world.delta_time;
    const max_distance: f32 = if (state.grid) 150 else 80;
    state.distance = std.math.clamp(
        state.distance * std.math.pow(f32, 0.9, @floatCast(wheel)),
        1.5,
        max_distance,
    );
    const top = surfaceRadius(world, .{ 0, 1, 0 }) + subject_height;
    world.camera.transform = if (state.grid) .{
        .position = .{
            0,
            top - state.distance * @sin(grid_pitch),
            state.distance * @cos(grid_pitch),
        },
        .rotation = nz.Quat(f32).angleAxis(grid_pitch, .{ 1, 0, 0 }),
    } else .{ .position = .{ 0, top + state.distance * 0.2, state.distance } };

    const loop: shared.entity.Loop = switch (state.slot) {
        .loop => |loop| loop,
        .action => .idle,
    };
    const count = if (state.grid) kinds.len else 1;
    for (0..count) |index| {
        const subject = world.getPtr(subjectId(index)) orelse continue;
        const up = if (state.grid) gridUp(index, state.planet_radius) else nz.Vec3(f32){ 0, 1, 0 };
        subject.motion.update = null;
        subject.transform.rotation = shared.math.rotationFromUp(up).mul(
            nz.Quat(f32).angleAxis(state.yaw, .{ 0, 1, 0 }),
        );
        subject.override_animation_loop = loop;
    }
}

fn surfaceRadius(world: *const World, up: nz.Vec3(f32)) f32 {
    return nz.vec.length(world.planet.surfacePoint(up));
}

pub fn labels(world: *World, state: *const State, out: []Label) []Label {
    const count = if (state.grid) kinds.len else 0;
    var len: usize = 0;
    for (0..count) |index| {
        const subject = world.getPtr(subjectId(index)) orelse continue;
        out[len] = .{
            .name = ModelRow.kindName(kinds[index]),
            .position = subject.transform.position,
            .selected = index == state.kind_index,
        };
        len += 1;
    }
    return out[0..len];
}

pub const Label = struct { name: []const u8, position: nz.Vec3(f32), selected: bool };
pub const max_labels = kinds.len;

/// Console form of the zoo panel:
/// `kind <name>`, `slot <loop|action>`, `clip <name|none>`, `play`, `grid`, `radius <n>`, `exit`.
pub fn parseCommand(line: []const u8, models: *const Models, state: *const State) Command {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = words.next() orelse return .none;
    const argument = words.rest();
    if (std.mem.eql(u8, verb, "exit")) return .exit;
    if (std.mem.eql(u8, verb, "play")) return .play_action;
    if (std.mem.eql(u8, verb, "grid")) return .toggle_grid;
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
    const slot = if (state.grid) state.kind_index else 0;
    const subject = world.getPtr(subjectId(slot)) orelse return .none;
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
