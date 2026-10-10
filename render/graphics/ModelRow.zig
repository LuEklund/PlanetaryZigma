//! Presentation of one entity kind: the shape of `assets/manifest/<kind>.zon`.
//! Without a file, the row comes from the kind's Zig spec.
const ModelRow = @This();

const std = @import("std");
const shared = @import("shared");
const entity = shared.entity;
const nz = shared.numz;

pub const dir_name = "manifest";

pub const Loops = struct {
    idle: ?[]const u8 = null,
    walk: ?[]const u8 = null,
    death: ?[]const u8 = null,
    stun: ?[]const u8 = null,
};

pub const Actions = struct {
    primary: ?[]const u8 = null,
    secondary: ?[]const u8 = null,
    utility: ?[]const u8 = null,
    equipment: ?[]const u8 = null,
    special: ?[]const u8 = null,
};

comptime {
    assertNamesMatch(Loops, entity.Loop);
    assertNamesMatch(Actions, entity.Action);
}

model: []const u8,
offset: nz.Transform3D(f32) = .{},
loops: Loops = .{},
actions: Actions = .{},
look_nodes: ?entity.ModelLookNodeNames = null,
overlay_root: ?[]const u8 = null,

pub fn fromSpec(kind: entity.Kind) ?ModelRow {
    const spec = kind.spec();
    const model = spec.model orelse return null;
    var row: ModelRow = .{
        .model = model.path,
        .offset = model.offset,
        .look_nodes = model.look_node_names,
        .overlay_root = model.overlay_root_name,
    };
    if (model.loop_clips) |loop_clips| {
        inline for (@typeInfo(Loops).@"struct".fields) |field| {
            @field(row.loops, field.name) = loop_clips.get(@field(entity.Loop, field.name));
        }
    }
    inline for (@typeInfo(Actions).@"struct".fields) |field| {
        const assigned = spec.skills.get(@field(entity.Action, field.name));
        @field(row.actions, field.name) = if (assigned) |skill| skill.clip else null;
    }
    return row;
}

pub fn loop(row: *const ModelRow, which: entity.Loop) ?[]const u8 {
    return switch (which) {
        inline else => |tag| @field(row.loops, @tagName(tag)),
    };
}

pub fn action(row: *const ModelRow, which: entity.Action) ?[]const u8 {
    return switch (which) {
        inline else => |tag| @field(row.actions, @tagName(tag)),
    };
}

pub fn setLoop(row: *ModelRow, which: entity.Loop, clip: ?[]const u8) void {
    switch (which) {
        inline else => |tag| @field(row.loops, @tagName(tag)) = clip,
    }
}

pub fn setAction(row: *ModelRow, which: entity.Action, clip: ?[]const u8) void {
    switch (which) {
        inline else => |tag| @field(row.actions, @tagName(tag)) = clip,
    }
}

/// "player", "tubloid", "lootbox": the manifest file stem.
pub fn kindName(kind: entity.Kind) []const u8 {
    return switch (kind) {
        .enemy => |enemy_kind| @tagName(enemy_kind),
        else => @tagName(kind),
    };
}

pub fn filePath(buffer: []u8, kind: entity.Kind) ![]const u8 {
    return std.fmt.bufPrint(buffer, dir_name ++ "/{s}.zon", .{kindName(kind)});
}

pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !ModelRow {
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(gpa);
    return std.zon.parse.fromSliceAlloc(ModelRow, gpa, source, &diagnostics, .{}) catch |err| {
        std.log.err("manifest: {f}", .{diagnostics});
        return err;
    };
}

pub fn free(gpa: std.mem.Allocator, row: ModelRow) void {
    std.zon.parse.free(gpa, row);
}

pub fn write(row: *const ModelRow, writer: *std.Io.Writer) !void {
    try std.zon.stringify.serialize(row.*, .{ .emit_default_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

pub fn save(row: *const ModelRow, io: std.Io, assets_dir: std.Io.Dir, kind: entity.Kind) !void {
    var path_buffer: [256]u8 = undefined;
    const path = try filePath(&path_buffer, kind);
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try row.write(&writer);
    try assets_dir.createDirPath(io, dir_name);
    try assets_dir.writeFile(io, .{ .sub_path = path, .data = writer.buffered() });
    std.log.info("saved {s}", .{path});
}

fn assertNamesMatch(Fields: type, Enum: type) void {
    const fields = @typeInfo(Fields).@"struct".fields;
    const tags = @typeInfo(Enum).@"enum".fields;
    if (fields.len != tags.len) @compileError(
        @typeName(Fields) ++ " out of sync with " ++ @typeName(Enum),
    );
    for (fields, tags) |field, tag| {
        if (!std.mem.eql(u8, field.name, tag.name)) @compileError(field.name ++ " != " ++ tag.name);
    }
}
