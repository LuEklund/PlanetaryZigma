const Item = @This();

const std = @import("std");
const nz = @import("numz");

id: @EnumLiteral(),
modifiers: struct {
    health: f32 = 0.0,
    speed: f32 = 0.0,
    damage: f32 = 0.0,
    attack_speed: f32 = 0.0,
    range: f32 = 0.0,
},

pub const Kind = e: {
    const TagInt = u16;

    var field_names: [items.len][]const u8 = undefined;
    var field_values: [items.len]TagInt = undefined;
    for (items, 0..) |item, i| field_names[i] = @tagName(item.id);
    for (0..items.len) |i| field_values[i] = i;

    break :e @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub const Model = struct {
    path: []const u8,
};

pub const Texture = struct {
    path: []const u8,
};

pub const items: []const Item = &.{
    .{
        .id = .oxygen_tank,
        .modifiers = .{
            .health = 90.0,
        },
    },
    .{
        .id = .gun,
        .modifiers = .{
            .damage = 1.5,
        },
    },
    .{
        .id = .energy_drink,
        .modifiers = .{
            .speed = 0.75,
        },
    },
    .{
        .id = .pickaxe,
        .modifiers = .{
            .attack_speed = 0.2,
        },
    },
};

pub const models: std.EnumArray(Kind, Model) = .init(.{
    .oxygen_tank = .{ .path = "objects/oxigen_tank.glb" }, // TODO: fix spelling for oxigen_tank glb
    .gun = .{ .path = "objects/gun.glb" },
    .energy_drink = .{ .path = "energy_drink.glb" },
    .pickaxe = .{ .path = "objects/pickaxe2.glb" },
});

pub const textures: std.EnumArray(Kind, Texture) = .init(.{
    .oxygen_tank = .{ .path = "items/oxygen_tank.png" },
    .gun = .{ .path = "items/damage.png" }, // TODO: rename damage.png to gun.png
    .energy_drink = .{ .path = "items/energy_drink.png" },
    .pickaxe = .{ .path = "items/pickaxe.png" },
});

pub fn get(kind: Kind) Item {
    return items[@intFromEnum(kind)];
}

pub fn name(self: Item) [:0]const u8 {
    inline for (items) |item| if (self.id == item.id) {
        const snake = @tagName(item.id);

        const title = title: {
            var buffer: [snake.len + 1:0]u8 = undefined;

            var upper = true;
            for (snake, 0..) |c, i| if (c == '_') {
                buffer[i] = ' ';
                upper = true;
            } else {
                buffer[i] = if (upper) std.ascii.toUpper(c) else c;
                upper = false;
            };

            buffer[snake.len] = 0;
            break :title buffer;
        };

        return &title;
    };

    unreachable;
}
