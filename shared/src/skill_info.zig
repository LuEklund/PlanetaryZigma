const std = @import("std");
const Skill = @import("entity.zig").Skill;

pub const Info = struct {
    name: []const u8,
    description: []const u8,
};

const infos: std.EnumArray(Skill, Info) = .init(.{
    .shoot = .{ .name = "Double Tap", .description = "Fire a fast bullet." },
    .spread_shot = .{ .name = "Scatter", .description = "Fire a shotgun burst in a cone." },
    .dash = .{ .name = "Tactical Dive", .description = "Dash forward along the ground." },
    .use_equipment = .{ .name = "Equipment", .description = "Use your equipment item." },
    .shoot_cube = .{ .name = "Cube Shot", .description = "Fire a slow heavy cube." },
    .melee = .{ .name = "Punch", .description = "Hit the enemy in front of you." },
    .arc_jump = .{ .name = "Leap", .description = "Jump in a high arc." },
    .plant = .{ .name = "Plant", .description = "Root in place." },
    .heal = .{ .name = "Heal", .description = "Restore health to nearby allies." },
    .charge = .{ .name = "Charge", .description = "Wind up, then rush forward." },
    .explode = .{ .name = "Detonate", .description = "Explode, damaging everything nearby." },
    .melee_cone = .{ .name = "Cleave", .description = "Wide swing that hits everything in front of you." },
    .ground_slam = .{ .name = "Ground Slam", .description = "Slam the ground, damaging enemies around you." },
    .grenade = .{ .name = "Frag Grenade", .description = "Throw a grenade that explodes on impact." },
    .railgun = .{ .name = "Railgun", .description = "Piercing shot that hits every enemy in a line." },
    .blink = .{ .name = "Blink", .description = "Teleport a long way in the direction you look." },
    .heal_pulse = .{ .name = "War Cry", .description = "Heal yourself and allies around you." },
    .artillery = .{ .name = "Artillery", .description = "Call down a strike where you aim." },
});

pub fn get(skill: Skill) Info {
    return infos.get(skill);
}
