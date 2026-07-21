const World = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const Physics = @import("system/Physics.zig");
const nz = shared.numz;

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity),
players: std.ArrayList(shared.entity.Id),
teleport_bosses: std.ArrayList(shared.entity.Id),
new_spawns: std.ArrayList(shared.entity.Id),
pending_despawns: std.ArrayList(PendingDespawn),
client_updates: std.ArrayList(ClientUpdate),
next_stage_requested: bool,
toggle_spawning_requested: bool,
dev_mode: bool,
teleporter_id: shared.entity.Id,
planet_radius: f32,
next_entity_id: u32,
next_stage: u32,
prng: std.Random.DefaultPrng,

pub const spawn_hover: f32 = 1.5;
pub const item_throw_speed: f32 = 18;

pub const item_launch_angle: f32 = std.math.pi / 4.0;

pub const PendingDespawn = struct {
    id: shared.entity.Id,
    remove: bool,
};

pub const ClientUpdate = union(enum) {
    spawned: shared.entity.Id,
    despawned: shared.entity.Id,
    stat: shared.net.UpdateStat,
    inventory: shared.net.UpdateInventory,
    event: shared.net.Event,
    currency: shared.net.SetCurrency,
};

pub const Camera = struct {
    pub const Mode = enum { follow, free };

    mode: Mode = .follow,
    yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
    pitch: f32 = 0,
    boom_offset: nz.Vec3(f32) = .{ 0, 0, 0 },
    transform: nz.Transform3D(f32) = .{},
};

pub const Controller = struct {
    input: shared.net.Input = .{},
};

pub const Entity = struct {
    id: shared.entity.Id = .none,
    flags: Flags = .{},
    kind: shared.entity.Kind = .unknown,
    owner_id: shared.entity.Id = .none,
    interacting: shared.entity.Id = .none,

    transform: nz.Transform3D(f32) = .{},
    replicated_velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    spawn_impulse: nz.Vec3(f32) = .{ 0, 0, 0 },
    collider: Physics.Collider = .{
        .shape = .{ .primitive = .{ .box = .{ .x = 1, .y = 1, .z = 1 } } },
        .motion_type = .dynamic,
        .object_layer = .moving,
    },
    controller: Controller = .{},
    camera: Camera = .{},
    lifetime: ?f32 = null,
    currency: u32 = 0,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .init(.initFill(0)),
    regen_carry: f32 = 0,

    last_attack: f32 = 0,

    pub const Flags = packed struct {
        invinsible: bool = false,
        is_teleporter_boss: bool = false,
        is_dead: bool = false,
    };

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (shared.entity.hasCollider(self.kind)) {
            switch (self.collider.shape) {
                .mesh => |*mesh| {
                    gpa.free(mesh.indices);
                    gpa.free(mesh.vertices);
                },
                .primitive => {},
            }
        }
    }
};

pub fn init(gpa: std.mem.Allocator, dev_mode: bool) !World {
    var entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty;
    try entities.ensureTotalCapacity(gpa, shared.max_entities);

    return .{
        .gpa = gpa,
        .entities = entities,
        .players = try .initCapacity(gpa, 16),
        .teleport_bosses = try .initCapacity(gpa, shared.max_entities),
        .new_spawns = try .initCapacity(gpa, shared.max_entities),
        .pending_despawns = try .initCapacity(gpa, shared.max_entities),
        .client_updates = try .initCapacity(gpa, 8192),
        .next_stage_requested = false,
        .toggle_spawning_requested = false,
        .dev_mode = dev_mode,
        .teleporter_id = .none,
        .planet_radius = 100,
        .next_entity_id = 1,
        .next_stage = 0,
        .prng = .init(0xACE1),
    };
}

pub fn deinit(self: *World) void {
    for (self.entities.values()) |*entity| {
        entity.deinit(self.gpa);
    }
    self.entities.deinit(self.gpa);
    self.players.deinit(self.gpa);
    self.teleport_bosses.deinit(self.gpa);
    self.new_spawns.deinit(self.gpa);
    self.pending_despawns.deinit(self.gpa);
    self.client_updates.deinit(self.gpa);
}

pub const SpawnError = error{ SpawnMaxSize, MaxEnemies, MaxPlayers };

pub fn spawn(self: *World, entity_info: Entity) SpawnError!*Entity {
    if (self.entities.entries.len >= shared.max_entities) {
        if (builtin.mode == .Debug) @panic("spawn: world full");
        return error.SpawnMaxSize;
    }
    if (entity_info.kind == .enemy and !entity_info.flags.is_teleporter_boss and self.enemyCount() >= shared.max_enemies) {
        return error.MaxEnemies;
    }
    if (builtin.mode != .Debug and entity_info.kind == .player and self.players.items.len >= shared.max_players) {
        return error.MaxPlayers;
    }
    const id: shared.entity.Id = @enumFromInt(self.next_entity_id);
    self.next_entity_id += 1;
    self.entities.putAssumeCapacity(id, entity_info);
    const entity = self.entities.getPtr(id).?;
    entity.id = id;
    if (entity.flags.is_teleporter_boss) self.teleport_bosses.appendAssumeCapacity(id);
    const kind_spec = shared.entity.spec(entity.kind);
    if (kind_spec.stats) |stats_spec| {
        var values = stats_spec;
        if (entity.kind == .enemy and entity.kind.enemy == .bloorp_lord) {
            values.set(.health, values.get(.health) * @as(f32, @floatFromInt(self.next_stage)));
        }
        entity.stats = .init(values);
    }
    entity.currency = kind_spec.currency;
    self.new_spawns.appendAssumeCapacity(id);
    return entity;
}

pub fn enemyCount(self: *const World) usize {
    var count: usize = 0;
    for (self.entities.values()) |*entity| {
        if (entity.kind == .enemy) count += 1;
    }
    return count;
}

pub fn getPtr(self: *World, id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn queueDespawn(self: *World, id: shared.entity.Id) void {
    self.pending_despawns.appendAssumeCapacity(.{ .id = id, .remove = false });
}

pub fn queueRemove(self: *World, id: shared.entity.Id) void {
    self.pending_despawns.appendAssumeCapacity(.{ .id = id, .remove = true });
}

pub fn giveItem(self: *World, player: *Entity, item: shared.Item, count: u8) ?u8 {
    if (player.inventory.get(item) >= 255) return null;
    const item_count = player.inventory.add(item, count);
    player.stats.gain(item, @floatFromInt(count));
    player.stats.refresh(player.inventory);
    self.client_updates.appendAssumeCapacity(.{ .inventory = .{
        .id = player.id,
        .item_kind = item,
        .set = item_count,
    } });
    for (std.enums.values(shared.Stats.Kind)) |stat_kind| {
        if (item.attributes().get(stat_kind) == 0) continue;
        self.client_updates.appendAssumeCapacity(.{ .stat = .{ .id = player.id, .stat_kind = stat_kind, .source = .none, .amount = .{ .set_max = @floatCast(player.stats.max.get(stat_kind)) } } });
        self.client_updates.appendAssumeCapacity(.{ .stat = .{ .id = player.id, .stat_kind = stat_kind, .source = .none, .amount = .{ .set_current = @floatCast(player.stats.current.get(stat_kind)) } } });
    }
    return item_count;
}

pub const HealthChange = enum { ignored, changed, killed };

pub fn removeHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (entity.flags.invinsible) return .ignored;
    const new_amount = (self.prng.random().float(f32) - 0.5) * 0.5 * amount + amount;
    return self.addHealth(entity, -new_amount, source);
}

pub fn addHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (!entity.kind.hasHealth()) return .ignored;
    const before = entity.stats.current.get(.health);
    if (before <= 0) return .ignored;
    const current = entity.stats.addCurrent(.health, amount);
    if (current == before) return .ignored;
    if (current <= 0) self.queueDespawn(entity.id);
    self.client_updates.appendAssumeCapacity(.{ .stat = .{
        .id = entity.id,
        .stat_kind = .health,
        .source = if (source) |source_entity| source_entity.id else .none,
        .amount = .{ .set_current = @floatCast(current) },
    } });
    return if (current <= 0) .killed else .changed;
}

pub fn flush(self: *World, physics: *Physics) !void {
    for (self.new_spawns.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (shared.entity.hasCollider(entity.kind)) {
            if (shared.entity.collider(entity.kind)) |kind_collider| {
                entity.collider = .{
                    .shape = .{ .primitive = kind_collider.shape },
                    .motion_type = kind_collider.motion,
                    .object_layer = kind_collider.layer,
                };
            }
            try physics.createBody(entity);
        }
        self.client_updates.appendAssumeCapacity(.{ .spawned = id });
    }
    self.new_spawns.clearRetainingCapacity();

    var currency_reward: u32 = 0;
    for (self.pending_despawns.items) |despawn| {
        const entity = self.getPtr(despawn.id) orelse continue;

        if (entity.collider.body_id) |body_id| {
            physics.destroyBody(body_id);
            entity.collider.body_id = null;
        }
        if (entity.kind == .player and !despawn.remove) {
            entity.flags.is_dead = true;
            entity.replicated_velocity = .{ 0, 0, 0 };
        } else {
            if (std.mem.indexOfScalar(shared.entity.Id, self.players.items, despawn.id)) |player_index| {
                _ = self.players.swapRemove(player_index);
            }
            if (entity.kind == .enemy) currency_reward += entity.currency;
            if (std.mem.indexOfScalar(shared.entity.Id, self.teleport_bosses.items, despawn.id)) |boss_index| {
                _ = self.teleport_bosses.swapRemove(boss_index);
                if (self.getPtr(self.teleporter_id)) |teleporter| {
                    const teleporter_up = shared.planetUp(teleporter.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                    _ = self.spawn(.{
                        .kind = .{ .item = .lightning },
                        .transform = .{
                            .position = teleporter.transform.position + nz.vec.scale(teleporter_up, World.spawn_hover + 10),
                            .rotation = teleporter.transform.rotation,
                        },
                        .spawn_impulse = shared.planetSurfaceLaunch(
                            teleporter.transform.position,
                            nz.vec.randomUnitVector(nz.Vec3(f32), self.prng.random()),
                            item_launch_angle,
                            item_throw_speed,
                        ),
                    }) catch {};
                }
            }
            entity.deinit(self.gpa);
            _ = self.entities.swapRemove(despawn.id);
        }
        self.client_updates.appendAssumeCapacity(.{ .despawned = despawn.id });
    }
    if (currency_reward > 0) for (self.players.items) |player_id| {
        const player = self.getPtr(player_id) orelse continue;
        player.currency += currency_reward;
        self.client_updates.appendAssumeCapacity(.{ .currency = .{ .amount = player.currency, .id = player_id } });
    };

    self.pending_despawns.clearRetainingCapacity();
}
