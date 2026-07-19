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
planet_radius: u32,
next_entity_id: u32,
next_stage: u32,
prng: std.Random.DefaultPrng,

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
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
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
        if (entity.kind == .enemy and entity.kind.enemy == .bloorpLord) {
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

pub fn removeHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) bool {
    if (!entity.kind.hasHealth()) return false;
    if (entity.flags.invinsible) return false;
    return self.addHealth(entity, -amount, source);
}

//TODO: bool the right kind of return?
pub fn addHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) bool {
    if (!entity.kind.hasHealth()) return false;
    const current = entity.stats.addCurrent(.health, amount);
    if (current <= 0) self.queueDespawn(entity.id);
    if (current <= 0 or entity.stats.max.get(.health) <= current) return true;
    self.client_updates.appendAssumeCapacity(.{ .stat = .{
        .id = entity.id,
        .stat_kind = .health,
        .source = if (source) |source_entity| source_entity.id else .none,
        .amount = .{ .set_current = @floatCast(current) },
    } });
    return true;
}

pub fn flush(self: *World, physics: *Physics) !void {
    for (self.new_spawns.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (shared.entity.hasCollider(entity.kind)) {
            if (shared.entity.colliderShape(entity.kind)) |primitive_shape| {
                entity.collider = .{
                    .shape = .{ .primitive = primitive_shape },
                    .motion_type = motionType(entity.kind),
                    .object_layer = objectLayer(entity.kind),
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
        if (std.mem.indexOfScalar(shared.entity.Id, self.players.items, despawn.id)) |player_index| {
            _ = self.players.swapRemove(player_index);
        }
        if (entity.collider.body_id) |body_id| {
            physics.destroyBody(body_id);
            entity.collider.body_id = null;
        }
        if (entity.kind == .player and !despawn.remove) {
            entity.flags.is_dead = true;
            entity.velocity = .{ 0, 0, 0 };
        } else {
            if (entity.kind == .enemy) currency_reward += entity.currency;
            if (std.mem.indexOfScalar(shared.entity.Id, self.teleport_bosses.items, despawn.id)) |boss_index| {
                _ = self.teleport_bosses.swapRemove(boss_index);
                if (self.getPtr(self.teleporter_id)) |teleporter| {
                    const random = self.prng.random();
                    const spawn_direction = shared.planetUp(teleporter.transform.position) orelse .{ 0, 1, 0 };
                    const transform = self.surfaceTransform(shared.planetSurfacePointNear(
                        spawn_direction,
                        @floatFromInt(self.planet_radius),
                        10,
                        20,
                        random,
                    ));
                    _ = try self.spawn(.{ .kind = .{ .item = .lightning }, .transform = transform });
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

pub fn motionType(kind: shared.entity.Kind) Physics.MotionType {
    return switch (kind) {
        .teleporter, .planet, .item, .lootbox => .static,
        else => .dynamic,
    };
}

pub fn objectLayer(kind: shared.entity.Kind) Physics.ObjectLayer {
    return switch (kind) {
        .teleporter, .planet => .non_moving,
        .item => .planet_only,
        else => .moving,
    };
}

pub fn spawnItem(world: *World, kind: shared.Item, vector_direction: nz.Vec3(f32)) !void {
    const transform = surfaceTransform(world, vector_direction);
    const item = try world.spawn(.{
        .kind = .{ .item = kind },
        .transform = transform,
    });
    std.log.debug("spawn item {t} id={d}", .{ kind, item.id });
}

pub fn surfaceTransform(world: *World, vector_direction: nz.Vec3(f32)) nz.Transform3D(f32) {
    const surface = shared.planetSurfacePoint(vector_direction, @floatFromInt(world.planet_radius));
    const planet_up = nz.vec.normalize(surface);
    return .{
        .position = surface + nz.vec.scale(planet_up, 1.5),
        .rotation = alignUpToPlanet(planet_up),
    };
}

pub fn alignUpToPlanet(planet_up: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
    const dot = std.math.clamp(nz.vec.dot(default_up, planet_up), -1.0, 1.0);
    if (dot >= 0.9999) return .identity;
    const axis = if (dot > -0.9999)
        nz.vec.normalize(nz.vec.cross(default_up, planet_up))
    else
        nz.Vec3(f32){ 1, 0, 0 };
    return nz.quat.Hamiltonian(f32).angleAxis(std.math.acos(dot), axis);
}
