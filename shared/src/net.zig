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

pub const ClientPacket = union(enum) {
    connect: Connect,
    disconnect: void,
    input: Input,
    chat: ChatSend,
    go_again: void,
    lobby: LobbyCommand,
    ping: PingRequest,
};

pub const PingRequest = struct {
    position: @Vector(3, f32),
    target: entity.Id,
};

pub const LobbyCommand = union(enum) {
    survivor: root.Survivor.Kind,
    ready: bool,
    difficulty: root.difficulty.Setting,
};

pub const LobbyPlayer = struct {
    id: entity.Id,
    survivor: root.Survivor.Kind,
    ready: bool,
};

pub const ServerPacket = union(enum) {
    acknowledge: Acknowledge,
    spawn_entity: SpawnEntity,
    spawn_planet: u32,
    despawn_entity: DespawnEntity,
    motion: UpdateMotion,
    server_tick: u32,
    health: UpdateHealth,
    event: Event,
    inventory: UpdateInventory,
    set_currency: SetCurrency,
    chat_message: ChatMessage,
    lobby_player: LobbyPlayer,
    lobby_difficulty: root.difficulty.Setting,
};

pub const Connect = struct {
    protocol_version: u32,
    player_name: PlayerName,
    survivor: root.Survivor.Kind,
};

pub const protocol_version: u32 = version: {
    @setEvalBranchQuota(100_000);
    break :version std.hash.Fnv1a_32.hash(
        protocolDescription(ClientPacket) ++ protocolDescription(ServerPacket) ++ root.version,
    );
};

fn protocolDescription(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |optional| "?" ++ protocolDescription(optional.child),
        .pointer => |pointer| "[]" ++ protocolDescription(pointer.child),
        .array => |array| std.fmt.comptimePrint(
            "[{d}]",
            .{array.len},
        ) ++ protocolDescription(array.child),
        .@"enum" => |@"enum"| description: {
            var description: []const u8 = "e" ++ @typeName(@"enum".tag_type) ++ "{";
            for (@"enum".fields) |field| description = description ++ field.name ++ ",";
            break :description description ++ "}";
        },
        .@"struct" => |@"struct"| description: {
            var description: []const u8 = "s{";
            for (@"struct".fields) |field| description = description ++ field.name ++ ":" ++ protocolDescription(
                field.type,
            ) ++ ",";
            break :description description ++ "}";
        },
        .@"union" => |@"union"| description: {
            var description: []const u8 = "u{";
            for (@"union".fields) |field| description = description ++ field.name ++ ":" ++ protocolDescription(
                field.type,
            ) ++ ",";
            break :description description ++ "}";
        },
        else => @typeName(T),
    };
}

pub const PlayerName = struct {
    name: [root.max_player_name_len]u8,

    pub fn copy(text: []const u8) PlayerName {
        var self: PlayerName = .{ .name = @splat(0) };
        const length = @min(text.len, root.max_player_name_len);
        @memcpy(self.name[0..length], text[0..length]);
        return self;
    }

    pub fn slice(self: *const PlayerName) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const ChatSend = struct {
    text_len: u16,
    text: []const u8,
};

pub const ChatMessage = struct {
    id: entity.Id,
    text_len: u16,
    text: []const u8,
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
    elite: root.Elite.Kind = .none,
    survivor: root.Survivor.Kind = .commando,
    data: SpawnEntityData,
};

pub const SpawnEntityData = union(enum) {
    none: void,
    is_teleporter_boss: void,
    player_name: PlayerName,
    item: root.Item.Kind,
};

pub const DespawnEntity = struct {
    id: entity.Id,
};

pub const Input = struct {
    keys: packed struct(u32) {
        move_forward: bool = false,
        move_backward: bool = false,
        move_right: bool = false,
        move_left: bool = false,
        jump: bool = false,
        sprint: bool = false,
        move_down: bool = false,
        aim: bool = false,

        reload: bool = false,

        interact: bool = false,
        use_equipment: bool = false,
        attack: bool = false,
        utility: bool = false,
        secondary: bool = false,
        special: bool = false,

        dev_f1: bool = false,
        dev_f2: bool = false,
        dev_f3: bool = false,
        dev_f4: bool = false,
        dev_f5: bool = false,
        dev_f6: bool = false,
        dev_f7: bool = false,
        dev_f8: bool = false,
        dev_f9: bool = false,
        dev_f10: bool = false,
        dev_f11: bool = false,
        dev_f12: bool = false,
        _padding: u6 = 0,
    } = .{},
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

pub const UpdateHealth = struct {
    id: entity.Id,
    source: entity.Id,
    amount: UpdateHealthAmount,
};

pub const UpdateHealthAmount = union(enum) {
    set_current: f16,
    set_max: f16,
};

pub const UpdateInventory = struct {
    id: entity.Id,
    item_kind: root.Item.Kind,
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

    pub const Action = struct {
        id: entity.Id,
        action: entity.Action,
        skill: entity.Skill,
    };

    pub const Stun = struct {
        id: entity.Id,
        duration: f32,
    };

    /// Ground warning for an incoming attack: where it lands and how wide.
    pub const Telegraph = struct {
        position: @Vector(3, f32),
        radius: f32,
    };

    pub const Ping = struct {
        pinger: entity.Id,
        position: @Vector(3, f32),
        target: entity.Id,
    };

    pub const Difficulty = struct {
        run_seconds: f32,
        coefficient: f32,
        level: f32,
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
    action: Action,
    stun: Stun,
    interact: Interact,
    effect: Effect,
    difficulty: Difficulty,
    ping: Ping,
    telegraph: Telegraph,
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
    const opcode = std.enums.fromInt(
        Opcode,
        try reader.takeInt(u16, endian),
    ) orelse return error.InvalidOpcode;
    switch (opcode) {
        inline else => |tag| return try parseFromOpcode(Packet, reader, tag),
    }
}

fn parseFromOpcode(
    comptime Packet: type,
    reader: *std.Io.Reader,
    comptime opcode: std.meta.Tag(Packet),
) !Packet {
    const tag_name = @tagName(opcode);
    const T = @FieldType(Packet, tag_name);
    const out = try unmarshal(null, reader, T);
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
        else => @compileError(
            "can not serialize type of " ++ @typeName(T) ++ " aka " ++ @tagName(@typeInfo(T)),
        ),
    }
}

fn unmarshal(opt_allocator: ?std.mem.Allocator, reader: *std.Io.Reader, Out: type) !Out {
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
            inline for (0..vector.len) |i| val[i] = try unmarshal(
                opt_allocator,
                reader,
                vector.child,
            );
            break :out val;
        },
        .@"struct" => |info| switch (info.layout) {
            .@"packed" => try reader.takeStruct(Out, endian),
            .auto, .@"extern" => out: {
                var out: Out = undefined;
                inline for (info.fields) |field| {
                    @field(out, field.name) = try unmarshalField(
                        opt_allocator,
                        reader,
                        Out,
                        &out,
                        field,
                    );
                }
                break :out out;
            },
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("can only deserialize tagged unions");
            const tag = std.enums.fromInt(
                Tag,
                try reader.takeInt(u16, endian),
            ) orelse return error.InvalidTag;
            switch (tag) {
                inline else => |t| {
                    const name = @tagName(t);
                    return @unionInit(
                        Out,
                        name,
                        try unmarshal(opt_allocator, reader, @FieldType(Out, name)),
                    );
                },
            }
        },
        else => unreachable,
    };
}

fn unmarshalField(
    opt_allocator: ?std.mem.Allocator,
    reader: *std.Io.Reader,
    comptime Out: type,
    out: *const Out,
    comptime field: std.builtin.Type.StructField,
) !field.type {
    return switch (@typeInfo(field.type)) {
        .pointer => unmarshalSlice(
            opt_allocator,
            reader,
            field.type,
            @field(out.*, field.name ++ "_len"),
        ),
        .array => |array| if (array.child == u8) (try reader.takeArray(array.len)).* else array: {
            var val: field.type = std.mem.zeroes(field.type);
            for (&val) |*element| element.* = try unmarshal(opt_allocator, reader, array.child);
            break :array val;
        },
        .@"enum" => reader.takeEnum(field.type, endian) catch |err| {
            std.log.err("{t} {s} {s}", .{ err, @typeName(Out), field.name });
            return err;
        },
        .bool, .int, .float, .vector, .@"struct", .@"union" => unmarshal(
            opt_allocator,
            reader,
            field.type,
        ),
        else => @compileError("can not read type of " ++ @typeName(field.type)),
    };
}

/// Without an allocator, byte slices alias the reader and other slices are skipped.
fn unmarshalSlice(
    opt_allocator: ?std.mem.Allocator,
    reader: *std.Io.Reader,
    comptime Slice: type,
    len: usize,
) !Slice {
    const Child = @typeInfo(Slice).pointer.child;
    if (Child == u8) {
        const bytes = try reader.take(len);
        try reader.discardAll((4 - (bytes.len % 4)) % 4);
        return if (opt_allocator) |allocator| try allocator.dupe(u8, bytes) else bytes;
    }
    const allocator = opt_allocator orelse {
        for (0..len) |_| _ = try unmarshal(null, reader, Child);
        return &.{};
    };
    const slice = try allocator.alloc(Child, len);
    for (slice) |*element| element.* = try unmarshal(allocator, reader, Child);
    return slice;
}
