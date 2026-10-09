const std = @import("std");
const Skill = @import("entity.zig").Skill;

pub const Effect = enum { damage, heal, none };

pub const Info = struct {
    name: []const u8,
    description: []const u8,
    effect: Effect,
};

const infos: std.EnumArray(Skill, Info) = .init(.{
    .shoot = .{ .name = "Double Tap", .description = "Fire a fast bullet.", .effect = .damage },
    .spread_shot = .{
        .name = "Scatter",
        .description = "Fire a shotgun burst in a cone.",
        .effect = .damage,
    },
    .dash = .{
        .name = "Tactical Dive",
        .description = "Dash forward along the ground.",
        .effect = .none,
    },
    .use_equipment = .{
        .name = "Equipment",
        .description = "Use your equipment item.",
        .effect = .none,
    },
    .shoot_cube = .{
        .name = "Cube Shot",
        .description = "Fire a slow heavy cube.",
        .effect = .damage,
    },
    .melee = .{
        .name = "Punch",
        .description = "Hit the enemy in front of you.",
        .effect = .damage,
    },
    .arc_jump = .{ .name = "Leap", .description = "Jump in a high arc.", .effect = .none },
    .plant = .{ .name = "Plant", .description = "Root in place.", .effect = .none },
    .heal = .{ .name = "Heal", .description = "Restore health to nearby allies.", .effect = .heal },
    .charge = .{
        .name = "Charge",
        .description = "Wind up, then rush forward.",
        .effect = .damage,
    },
    .explode = .{
        .name = "Detonate",
        .description = "Explode, damaging everything nearby.",
        .effect = .damage,
    },
    .melee_cone = .{
        .name = "Cleave",
        .description = "Wide swing that hits everything in front of you.",
        .effect = .damage,
    },
    .ground_slam = .{
        .name = "Ground Slam",
        .description = "Slam the ground, damaging enemies around you.",
        .effect = .damage,
    },
    .grenade = .{
        .name = "Frag Grenade",
        .description = "Throw a grenade that explodes on impact.",
        .effect = .damage,
    },
    .railgun = .{
        .name = "Railgun",
        .description = "Piercing shot that hits every enemy in a line.",
        .effect = .damage,
    },
    .blink = .{
        .name = "Blink",
        .description = "Teleport a long way in the direction you look.",
        .effect = .none,
    },
    .heal_pulse = .{
        .name = "War Cry",
        .description = "Heal yourself and allies around you.",
        .effect = .heal,
    },
    .artillery = .{
        .name = "Artillery",
        .description = "Call down a strike where you aim.",
        .effect = .damage,
    },
});

pub fn get(skill: Skill) Info {
    return infos.get(skill);
}
