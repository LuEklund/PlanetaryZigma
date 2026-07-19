const std = @import("std");
const root = @import("root.zig");
const entity = root.entity;

pub const endian: std.builtin.Endian = .little;

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
    update_event: Event,
    update_inventory: UpdateInventory,
    update_player_name: PlayerNameUpdate,
    set_currency: SetCurrency,
};

// ── Payloads ────────────────────────────────────────────────────────────────

pub const DevCommand = enum(u8) {
    none,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Connect = struct {
    protocol_version: u32,
    name_len: u16,
    name: []const u8,
};

// Comptime fingerprint of the entire wire format. Changes if and only if the
// structural layout reachable from ClientPacket/ServerPacket changes;
pub const protocol_version: u32 = version: {
    @setEvalBranchQuota(100_000);
    break :version std.hash.Fnv1a_32.hash(protocolDescription(ClientPacket) ++ protocolDescription(ServerPacket));
};

fn protocolDescription(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |optional| "?" ++ protocolDescription(optional.child),
        .pointer => |pointer| "[]" ++ protocolDescription(pointer.child),
        .array => |array| std.fmt.comptimePrint("[{d}]", .{array.len}) ++ protocolDescription(array.child),
        .@"enum" => |@"enum"| description: {
            var description: []const u8 = "e" ++ @typeName(@"enum".tag_type) ++ "{";
            for (@"enum".fields) |field| description = description ++ field.name ++ ",";
            break :description description ++ "}";
        },
        .@"struct" => |@"struct"| description: {
            var description: []const u8 = "s{";
            for (@"struct".fields) |field| description = description ++ field.name ++ ":" ++ protocolDescription(field.type) ++ ",";
            break :description description ++ "}";
        },
        .@"union" => |@"union"| description: {
            var description: []const u8 = "u{";
            for (@"union".fields) |field| description = description ++ field.name ++ ":" ++ protocolDescription(field.type) ++ ",";
            break :description description ++ "}";
        },
        else => @typeName(T),
    };
}

pub const PlayerName = struct {
    name_len: u16,
    name: []const u8,
};

pub const PlayerNameUpdate = struct {
    id: entity.Id,
    name_len: u16,
    name: []const u8,
};

pub const Acknowledge = struct {
    id: entity.Id,
    tick: u32,
};

pub const SpawnEntity = struct {
    id: entity.Id,
    kind: entity.Kind,
    position: @Vector(3, f32) = @splat(0),
    rotation: @Vector(4, f32) = .{ 0, 0, 0, 1 },
    velocity: @Vector(3, f32) = @splat(0),
    tick: u32 = 0,
    currency: u32 = 0,
    data: SpawnEntityData,
};

pub const SpawnEntityData = union(enum) {
    none: void,
    planet_radius: u32,
    is_teleporter_boss: void,
    player_name: PlayerName,
};

pub const DespawnEntity = struct {
    id: entity.Id,
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
        e: bool = false,
        mouse_button_left: bool = false,
        mouse_button_right: bool = false,
        _padding: u6 = 0,
    } = .{},
    dev_command: DevCommand = .none,
    camera_rotation: @Vector(4, f32) = .{ 0, 0, 0, 1 },
    camera_position: @Vector(3, f32) = .{ 0, 0, 0 },
};

pub const UpdateMotion = struct {
    id: entity.Id,
    position: @Vector(3, f32),
    velocity: @Vector(3, f32),
    rotation: @Vector(4, f32),
    tick: u32,
};

pub const UpdateTransform = struct {
    id: entity.Id,
    position: @Vector(3, f16),
    rotation: @Vector(4, f16),
};

pub const UpdateStat = struct {
    id: entity.Id,
    stat_kind: root.Stats.Kind,
    source: entity.Id,
    amount: UpdateStatAmount,
};

pub const UpdateStatAmount = union(enum) {
    set_current: f16,
    set_max: f16,
};

pub const UpdateInventory = struct {
    id: entity.Id,
    item_kind: root.Item,
    set: u8,
};

pub const SetCurrency = struct {
    id: entity.Id,
    amount: u32,
};

pub const Event = union(enum) {
    pub const Interact = struct {
        interactor: entity.Id,
        interacted: entity.Id,
    };

    pub const Effect = union(enum) {
        pub const Lightning = struct {
            pub const max_targets = 4;

            start_position: @Vector(3, f32),
            targets: [max_targets]entity.Id,
        };

        rocket_impact: @Vector(3, f32),
        lightning: Lightning,
    };

    teleport_start: void,
    teleporter_charge: f16,
    new_stage: u32,
    attack: entity.Id,
    interact: Interact,
    effect: Effect,
};

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
    const opcode = std.enums.fromInt(Opcode, try reader.takeInt(u16, endian)) orelse return error.InvalidOpcode;
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
            comptime std.debug.assert(pointer.size == .slice);
            if (pointer.child == u8) {
                try writer.writeAll(value);
                try writer.splatByteAll(0, (4 - (value.len % 4)) % 4);
            } else try writer.writeSliceEndian(pointer.child, value, endian);
        },
        .array => |array| {
            if (array.child == u8) {
                try writer.writeAll(&value);
            } else try writer.writeSliceEndian(array.child, &value, endian);
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
                try writer.writeInt(u16, @intFromEnum(tag), endian);
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
        .array => |array| out: {
            var val: Out = undefined;
            if (array.child == u8) {
                try reader.readSliceAll(&val);
            } else try reader.readSliceEndian(array.child, &val, endian);
            break :out val;
        },
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
            const tag = std.enums.fromInt(Tag, try reader.takeInt(u16, endian)) orelse return error.InvalidTag;
            switch (tag) {
                inline else => |t| {
                    const name = @tagName(t);
                    return @unionInit(Out, name, try unmarshal(opt_allocator, reader, @FieldType(Out, name), deserialize_slices));
                },
            }
        },
        else => unreachable,
    };
}
