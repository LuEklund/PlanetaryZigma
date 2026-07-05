const std = @import("std");
const root = @import("root.zig");
const Entity = root.Entity;

pub const endian: std.builtin.Endian = .little;

/// Queue of packets of one direction. Server holds a ClientPacket queue per client.
pub fn PacketQueue(comptime Packet: type) type {
    return struct {
        commands: std.ArrayList(Packet) = .empty,
        mutex: std.Io.Mutex = .init,
        pub fn deinit(self: *@This(), gpa: std.mem.Allocator, io: std.Io) !void {
            try self.mutex.lock(io);
            self.commands.deinit(gpa);
            self.mutex.unlock(io);
        }
    };
}

// ── Packets, split by direction ─────────────────────────────────────────────
// Each side only ever receives one direction, so its switch over the packet is
// naturally exhaustive (no `else` swallowing a forgotten variant). Opcode spaces
// are independent because direction is known from the socket.

/// client → server
pub const ClientPacket = union(enum) {
    connect: Connect,
    disconnect: void,
    input: Input,
};

/// server → client
pub const ServerPacket = union(enum) {
    acknowledge: Acknowledge,
    spawn_entity: SpawnEntity,
    despawn_entity: DespawnEntity,
    update_motion: UpdateMotion,
    server_tick: u32,
    update_stat: UpdateStat,
    update_animation_state: UpdateAnimationState,
    update_event: Event,
    update_inventory: UpdateInventory,
};

// ── Payloads ────────────────────────────────────────────────────────────────

pub const Connect = struct {
    name_len: u16,
    name: []const u8,
};

pub const Acknowledge = struct {
    id: u32,
    tick: u32,
};

pub const SpawnEntity = struct {
    id: u32,
    kind: Entity.Kind,
    position: @Vector(3, f32) = @splat(0),
    rotation: @Vector(4, f32) = .{ 0, 0, 0, 1 },
    data: union(enum(u16)) {
        none: void,
        bullet_velocity: @Vector(3, f32),
        planet_radius: u32,
        is_teleporter_boss: void,
    },
};

pub const DespawnEntity = struct {
    id: u32,
};

pub const Input = struct {
    keys: packed struct(u16) {
        w: bool = false,
        s: bool = false,
        d: bool = false,
        a: bool = false,
        space: bool = false,
        l_shift: bool = false,
        r: bool = false,
        k: bool = false,
        e: bool = false,
        mouse_button_left: bool = false,
        mouse_button_right: bool = false,
        _padding: u5 = 0,
    } = .{},
    mouse_wheel: f64 = 0,
    mouse_delta: [2]f64 = .{ 0, 0 },
    camera_yaw_rotation: @Vector(4, f32) = .{ 0, 0, 0, 1 },
};

pub const UpdateMotion = struct {
    id: u32,
    position: @Vector(3, f32),
    velocity: @Vector(3, f32),
    rotation: @Vector(4, f32),
    tick: u32,
};

pub const UpdateTransform = struct {
    id: u32,
    position: @Vector(3, f16),
    rotation: @Vector(4, f16),
};

pub const UpdateStat = struct {
    id: u32,
    stat_kind: root.Stat.Kind,
    amount: union(enum(u16)) {
        set_current: f16,
        set_max: f16,
    },
};

pub const UpdateInventory = struct {
    id: u32,
    item_kind: root.Item.Kind,
    set: u8,
};

pub const UpdateAnimationState = struct {
    id: u32,
    state: Entity.State,
};

pub const Event = union(enum(u16)) {
    teleport_start: void,
    teleporter_charge: f16,
    new_stage: void,
};

// ── Wire format (generic over packet direction) ─────────────────────────────
pub fn write(comptime Packet: type, self: Packet, writer: *std.Io.Writer) !void {
    switch (self) {
        inline else => |payload, tag| {
            try writer.writeInt(u16, @intFromEnum(tag), endian);
            try marshal(writer, payload);
        },
    }
}

pub fn parse(comptime Packet: type, reader: *std.Io.Reader) !Packet {
    const Opcode = std.meta.Tag(Packet);
    const opcode: Opcode = @enumFromInt(try reader.takeInt(u16, endian));
    switch (opcode) {
        inline else => |tag| return try parseFromOpcode(Packet, reader, tag),
    }
}

fn parseFromOpcode(comptime Packet: type, reader: *std.Io.Reader, comptime opcode: std.meta.Tag(Packet)) !Packet {
    const tag_name = @tagName(opcode);
    const T = @FieldType(Packet, tag_name);
    const out = try unmarshal(null, reader, T, true);
    return @unionInit(Packet, tag_name, out);
}

fn marshal(writer: *std.Io.Writer, value: anytype) !void {
    const T: type = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => return,
        .bool => try writer.writeInt(u8, @intFromBool(value), endian),
        .int => try writer.writeInt(T, value, endian),
        .float => |float| try writer.writeInt(@Int(.signed, float.bits), @bitCast(value), endian),
        .pointer => |pointer| {
            if (pointer.child == u8)
                try writer.writeAll(value)
            else
                try writer.writeSliceEndian(pointer.child, value, endian);
        },
        .array => |array| if (array.child == u8)
            try writer.writeAll(&value)
        else for (value) |item| {
            try marshal(writer, item);
        },
        .vector => |vector| inline for (0..vector.len) |i| {
            try marshal(writer, value[i]);
        },
        .@"struct" => |@"struct"| switch (@"struct".layout) {
            .auto => inline for (std.meta.fields(T)) |field| {
                const field_value = @field(value, field.name);
                try marshal(writer, field_value);
            },
            .@"extern" => @compileError("preferred to not serialize structs with extern layout"),
            .@"packed" => try writer.writeStruct(value, endian),
        },
        .@"enum" => |@"enum"| try writer.writeInt(@"enum".tag_type, @intFromEnum(value), endian),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                try writer.writeInt(@typeInfo(@TypeOf(tag)).@"enum".tag_type, @intFromEnum(tag), endian);
                try marshal(writer, payload);
            },
        },
        .enum_literal => try writer.writeAll(@tagName(value)),
        else => @compileError("can not serialize type of " ++ @typeName(T) ++ " aka " ++ @tagName(@typeInfo(T))),
    }
}

fn unmarshal(opt_allocator: ?std.mem.Allocator, reader: *std.Io.Reader, Out: type, deserialize_slices: bool) !Out {
    return switch (@typeInfo(Out)) {
        .void => return,
        .bool => try reader.takeByte() == 1,
        .int => try reader.takeInt(Out, endian),
        .float => |float| @bitCast(try reader.takeInt(@Int(.signed, float.bits), endian)),
        .@"enum" => try reader.takeEnum(Out, endian),
        .vector => |vector| out: {
            var val: Out = @splat(0);
            inline for (0..vector.len) |i| val[i] = try unmarshal(opt_allocator, reader, vector.child, deserialize_slices);
            break :out val;
        },
        .@"struct" => {
            var out: Out = undefined;

            inline for (@typeInfo(Out).@"struct".fields) |field| @field(out, field.name) = switch (@typeInfo(field.type)) {
                .bool => try reader.takeByte() == 1,
                .int => try reader.takeInt(field.type, endian),
                .float => |float| @bitCast(try reader.takeInt(@Int(.signed, float.bits), endian)),
                .pointer => |ptr| if (deserialize_slices) slice: {
                    const element_len_name = field.name ++ "_len";
                    std.debug.assert(@typeInfo(@FieldType(Out, element_len_name)) == .int);
                    const element_len: usize = @field(out, element_len_name);
                    if (ptr.child == u8) {
                        const slice = try reader.take(element_len);
                        reader.toss((4 - (slice.len % 4)) % 4);
                        break :slice if (opt_allocator) |allocator| try allocator.dupe(u8, slice) else slice;
                    } else {
                        if (opt_allocator) |allocator| {
                            const slice = try allocator.alloc(ptr.child, element_len);

                            for (0..element_len) |i| {
                                slice[i] = try unmarshal(allocator, reader, ptr.child, endian, true);
                            }
                            break :slice slice;
                        } else {
                            for (0..element_len) |_| {
                                _ = try unmarshal(null, reader, ptr.child, endian, true);
                            }

                            break :slice &.{};
                        }
                    }
                } else &.{},
                .array => |array| if (array.child == u8) (try reader.takeArray(array.len)).* else array: {
                    var val: field.type = std.mem.zeroes(field.type);
                    for (0..array.len) |i| {
                        val[i] = try unmarshal(opt_allocator, reader, array.child, deserialize_slices);
                    }
                    break :array val;
                },
                .vector => |vector| vector: {
                    var val: field.type = @splat(0);
                    inline for (0..vector.len) |i| {
                        val[i] = try unmarshal(opt_allocator, reader, vector.child, deserialize_slices);
                    }
                    break :vector val;
                },
                .@"enum" => e: {
                    break :e reader.takeEnum(field.type, endian) catch |err| {
                        std.log.err("{s} {s} {s}", .{ @errorName(err), @typeName(Out), field.name });
                        return err;
                    };
                },
                .@"struct" => |s| switch (s.layout) {
                    .auto, .@"extern" => try unmarshal(opt_allocator, reader, field.type, deserialize_slices),
                    .@"packed" => try reader.takeStruct(field.type, endian),
                },
                .@"union" => try unmarshal(opt_allocator, reader, field.type, deserialize_slices),
                else => @compileError("can not read type of " ++ @typeName(field.type) ++ " aka " ++ @tagName(@typeInfo(field.type))),
            };
            return out;
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("can only deserialize tagged unions");
            switch (try reader.takeEnum(Tag, endian)) {
                inline else => |tag| {
                    const name = @tagName(tag);
                    return @unionInit(Out, name, try unmarshal(opt_allocator, reader, @FieldType(Out, name), deserialize_slices));
                },
            }
        },
        else => unreachable,
    };
}
