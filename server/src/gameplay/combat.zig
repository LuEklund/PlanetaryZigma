const World = @import("../World.zig");
const Entity = World.Entity;

pub const HealthChange = enum { ignored, changed, killed };

pub fn removeHealth(world: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (entity.flags.is_dead or entity.max_health <= 0) return .ignored;
    if (entity.flags.invincible and amount > 0) return .ignored;
    const random = world.prng.random();
    var new_amount = (random.float(f32) - 0.5) * 0.5 * amount + amount;
    new_amount = @min(new_amount, amount);
    if (source) |source_entity| {
        if (random.float(f32) < source_entity.stat(.critical_chance)) new_amount *= 2;

        if (random.float(f32) < entity.stat(.block_chance)) new_amount = 0;

        if (random.float(f32) < source_entity.stat(.stun_chance)) {
            const stun_duration: f32 = 2;
            entity.un_stun_at = world.elapsed_time + stun_duration;
            world.client_updates.appendAssumeCapacity(.{ .event = .{ .stun = .{ .id = entity.id, .duration = stun_duration } } });
        }
    }
    return addHealth(world, entity, -new_amount, source);
}

pub fn addHealth(world: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (entity.max_health <= 0) return .ignored;
    const before = entity.health;
    if (before <= 0) return .ignored;
    var current = @min(entity.max_health, entity.health + amount);
    entity.health = current;
    if (current == before) return .ignored;
    if (current <= 0 and entity.kind == .target_dummy) {
        current = entity.max_health;
        entity.health = current;
        world.client_updates.appendAssumeCapacity(.{ .health = .{
            .id = entity.id,
            .source = if (source) |source_entity| source_entity.id else .none,
            .amount = .{ .set_current = @floatCast(current) },
        } });
        return .changed;
    }
    if (current <= 0) world.queueDespawn(entity.id);

    world.client_updates.appendAssumeCapacity(.{ .health = .{
        .id = entity.id,
        .source = if (source) |source_entity| source_entity.id else .none,
        .amount = .{ .set_current = @floatCast(current) },
    } });
    return if (current <= 0) .killed else .changed;
}
