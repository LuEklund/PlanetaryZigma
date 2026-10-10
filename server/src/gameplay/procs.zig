const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Entity = World.Entity;
const combat = @import("combat.zig");

pub const Hit = struct {
    attacker_id: shared.entity.Id,
    victim_id: shared.entity.Id,
    damage: f32,
    victim_health_fraction_before: f32,
    killed: bool,
    victim_position: nz.Vec3(f32),
};

pub fn afterHit(world: *World, hit: Hit) void {
    if (world.getPtrRaw(hit.attacker_id)) |attacker| {
        runProcs(world, attacker, .on_hit, hit);
        if (hit.killed) runProcs(world, attacker, .on_kill, hit);
    }
    if (world.getPtr(hit.victim_id)) |victim| runProcs(world, victim, .on_hurt, hit);
}

fn runProcs(world: *World, owner: *Entity, trigger: shared.Item.Trigger, hit: Hit) void {
    for (std.enums.values(shared.Item.Kind)) |item_kind| {
        const stacks = owner.inventory.get(item_kind);
        if (stacks == 0) continue;
        for (shared.Item.get(item_kind).procs) |proc| {
            if (proc.trigger != trigger) continue;
            if (proc.chance < 1 and world.prng.random().float(f32) >= proc.chance) continue;
            resolve(world, owner, proc.effect, @floatFromInt(stacks), hit);
        }
    }
}

fn resolve(
    world: *World,
    owner: *Entity,
    effect: shared.Item.ProcEffect,
    stacks: f32,
    hit: Hit,
) void {
    switch (effect) {
        .heal => |amount| _ = combat.addHealth(world, owner, amount * stacks, null),
        .leech => |fraction| _ = combat.addHealth(
            world,
            owner,
            hit.damage * fraction * stacks,
            null,
        ),
        .gold => |amount| {
            if (owner.kind != .player) return;
            owner.currency += amount * @as(u32, @intFromFloat(stacks));
            world.client_updates.appendAssumeCapacity(
                .{ .set_currency = .{ .id = owner.id, .amount = owner.currency } },
            );
        },
        .blast => |blast| {
            const radius = blast.radius + blast.radius_per_stack * (stacks - 1);
            const damage = owner.stat(.damage) * blast.damage_fraction;
            for (world.entities.values()) |*candidate| {
                if (candidate.max_health <= 0 or candidate.flags.is_dead) continue;
                if (candidate.kind.allied(owner.kind) or candidate.kind.projectileKind() != null) continue;
                if (nz.vec.distance(
                    candidate.transform.position,
                    hit.victim_position,
                ) > radius) continue;
                _ = combat.dealDamage(world, candidate, damage, owner, false);
            }
            world.client_updates.appendAssumeCapacity(
                .{ .event = .{ .effect = .{ .rocket_impact = hit.victim_position } } },
            );
        },
        .healthy_bonus => |bonus| {
            if (hit.killed or hit.victim_health_fraction_before < bonus.threshold) return;
            const victim = world.getPtr(hit.victim_id) orelse return;
            _ = combat.dealDamage(
                world,
                victim,
                hit.damage * bonus.damage_fraction * stacks,
                owner,
                false,
            );
        },
        .thorns => |fraction| {
            if (owner.id != hit.victim_id) return;
            const attacker = world.getPtr(hit.attacker_id) orelse return;
            _ = combat.dealDamage(world, attacker, hit.damage * fraction * stacks, owner, false);
        },
    }
}
