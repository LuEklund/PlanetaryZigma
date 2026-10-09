const World = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const Physics = @import("system/Physics.zig");
const Navmesh = @import("system/Navmesh.zig");
const nz = shared.numz;

entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity),
players: std.ArrayList(shared.entity.Id),
teleport_bosses: std.ArrayList(shared.entity.Id),
new_spawns: std.ArrayList(shared.entity.Id),
pending_despawns: std.ArrayList(PendingDespawn),
planet: shared.Planet,
navmesh: Navmesh,
options: Options,
place: Place,
director: Director,
client_updates: std.ArrayList(shared.net.ServerPacket),
spawned: std.ArrayList(shared.entity.Id),
physics_commands: std.ArrayList(Physics.Command),
impacts: std.ArrayList(Physics.Impact),
next_stage_requested: bool,
go_again_requested: bool,
start_round_requested: bool,
toggle_spawning_requested: bool,
dev_mode: bool,
teleporter_id: shared.entity.Id,
next_entity_id: u32,
stage: u32,
prng: std.Random.DefaultPrng,
elapsed_time: f32,
delta_time: f32,
tick: u32,
run_seconds: f32,
difficulty_setting: shared.difficulty.Setting,

world_unstun_at: f32 = 0,

pub const ship_room_altitude_factor: f32 = 2.5;
pub const ship_room_stand_height: f32 = 2;
pub const ship_planet_radius: u32 = 26;

pub const item_throw_speed: f32 = 18;

pub const item_launch_angle: f32 = std.math.pi / 4.0;

pub const PendingDespawn = struct {
    id: shared.entity.Id,
    remove: bool,
};

pub const Place = enum { ship, planet };

pub const Options = struct {
    draw_flow_field: bool,
    draw_chunk_borders: bool,
};

pub const Director = struct {
    credits: f32,
    salary_per_second: f32,
    last_salary: f32,
    spawning: bool,
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
    reload_held: bool = false,
    resync_requested: bool = false,
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
    body_id: ?Physics.BodyId = null,
    item: ?shared.Item.Kind = null,
    controller: Controller = .{},
    camera: Camera = .{},
    lifetime: f32 = 0,
    currency: u32 = 0,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    health: f32 = 0,
    max_health: f32 = 0,
    damage: f32 = 0,
    regen_carry: f32 = 0,
    level: f32 = 1,
    elite: shared.Elite.Kind = .none,
    survivor: shared.Survivor.Kind = .commando,
    ready: bool = false,
    ai: Ai = .{},

    un_stun_at: f32 = 0,

    last_used: std.EnumArray(shared.entity.Action, f32) = .initFill(0),
    last_interact: f32 = 0,
    mode: Mode = .falling,

    pub fn stat(self: *const Entity, stat_kind: shared.Item.Stat) f32 {
        const value = shared.Item.Stat.value(stat_kind, shared.entity.baseStats(self.kind, self.survivor), self.inventory);
        return switch (stat_kind) {
            .health => value * shared.difficulty.healthMultiplier(self.level) * shared.Elite.get(self.elite).health_multiplier,
            .damage => value * shared.difficulty.damageMultiplier(self.level) * shared.Elite.get(self.elite).damage_multiplier,
            else => value,
        };
    }

    pub const Mode = enum {
        walking,
        falling,
    };

    pub const Ai = struct {
        phase: Phase = .approach,
        phase_until: f32 = 0,
        direction: nz.Vec3(f32) = .{ 0, 0, 0 },
        struck: bool = false,

        pub const Phase = enum { approach, windup, dash, fuse };
    };

    pub const Flags = packed struct {
        invincible: bool = false,
        is_teleporter_boss: bool = false,
        is_dead: bool = false,
    };
};

pub fn init(gpa: std.mem.Allocator, dev_mode: bool) !World {
    var entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty;
    try entities.ensureTotalCapacity(gpa, shared.max_entities);

    return .{
        .entities = entities,
        .players = try .initCapacity(gpa, 16),
        .teleport_bosses = try .initCapacity(gpa, shared.max_entities),
        .new_spawns = try .initCapacity(gpa, shared.max_entities),
        .pending_despawns = try .initCapacity(gpa, shared.max_entities),
        .client_updates = try .initCapacity(gpa, 8192),
        .spawned = try .initCapacity(gpa, 8192),
        .physics_commands = try .initCapacity(gpa, shared.max_entities * 4),
        .impacts = try .initCapacity(gpa, shared.max_entities),
        .next_stage_requested = false,
        .go_again_requested = false,
        .start_round_requested = false,
        .toggle_spawning_requested = false,
        .dev_mode = dev_mode,
        .teleporter_id = .none,
        .planet = .{
            .planet_radius = ship_planet_radius,
            .chunks = .empty,
            .job = null,
            .uploads = .empty,
            .removes = .empty,
        },
        .navmesh = .empty,
        .options = .{ .draw_flow_field = true, .draw_chunk_borders = true },
        .place = .ship,
        .director = .{ .credits = 0, .salary_per_second = 10, .last_salary = 0, .spawning = false },
        .run_seconds = 0,
        .difficulty_setting = .rainstorm,
        .next_entity_id = 1,
        .stage = 0,
        .prng = .init(0xACE1),
        .elapsed_time = 0,
        .delta_time = 0,
        .tick = 0,
    };
}

pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
    self.entities.deinit(gpa);
    self.players.deinit(gpa);
    self.teleport_bosses.deinit(gpa);
    self.new_spawns.deinit(gpa);
    self.pending_despawns.deinit(gpa);
    self.client_updates.deinit(gpa);
    self.spawned.deinit(gpa);
    self.physics_commands.deinit(gpa);
    self.impacts.deinit(gpa);
    self.planet.deinit(gpa);
    self.navmesh.deinit(gpa);
}

pub const SpawnError = error{ SpawnMaxSize, MaxEnemies };

pub fn spawn(self: *World, entity_info: Entity) SpawnError!*Entity {
    if (self.entities.entries.len >= shared.max_entities) {
        if (builtin.mode == .Debug) @panic("spawn: world full");
        return error.SpawnMaxSize;
    }
    if (entity_info.kind == .enemy and !entity_info.flags.is_teleporter_boss and self.enemyCount() >= shared.max_enemies) {
        return error.MaxEnemies;
    }
    const id: shared.entity.Id = @enumFromInt(self.next_entity_id);
    self.next_entity_id += 1;
    self.entities.putAssumeCapacity(id, entity_info);
    const entity = self.entities.getPtr(id).?;
    entity.id = id;
    if (entity.flags.is_teleporter_boss) self.teleport_bosses.appendAssumeCapacity(id);
    const difficulty_coefficient = self.difficultyCoefficient();
    const base_currency = entity.kind.spec().currency;
    switch (entity.kind) {
        .enemy => {
            entity.level = shared.difficulty.level(difficulty_coefficient, self.players.items.len);
            const elite = shared.Elite.get(entity.elite);
            entity.currency = shared.difficulty.killReward(base_currency, difficulty_coefficient * elite.cost_multiplier);
            for (elite.granted_items) |grant| _ = entity.inventory.add(grant.item, grant.count);
        },
        .lootbox => entity.currency = shared.difficulty.chestCost(base_currency, difficulty_coefficient),
        else => entity.currency = base_currency,
    }
    entity.max_health = entity.stat(.health);
    entity.health = entity.max_health;
    self.new_spawns.appendAssumeCapacity(id);
    return entity;
}

pub fn difficultyCoefficient(self: *const World) f32 {
    return shared.difficulty.coefficient(self.difficulty_setting, self.run_seconds, self.players.items.len, self.stage -| 1);
}

pub fn enemyCount(self: *const World) usize {
    var count: usize = 0;
    for (self.entities.values()) |*entity| {
        if (entity.kind == .enemy) count += 1;
    }
    return count;
}

pub fn getPtr(self: *World, id: shared.entity.Id) ?*Entity {
    const entity = self.entities.getPtr(id) orelse return null;
    if (entity.flags.is_dead) return null;
    return entity;
}

pub fn getPtrRaw(self: *World, id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn queueDespawn(self: *World, id: shared.entity.Id) void {
    const entity = self.getPtr(id) orelse return;
    entity.flags.is_dead = true;
    self.pending_despawns.appendAssumeCapacity(.{ .id = id, .remove = false });
}

pub fn queueRemove(self: *World, id: shared.entity.Id) void {
    self.pending_despawns.appendAssumeCapacity(.{ .id = id, .remove = true });
}

pub fn act(self: *World, command: Physics.Command) void {
    self.physics_commands.appendAssumeCapacity(command);
}

pub fn rayCast(physics: *Physics, start: nz.Vec3(f32), translation: nz.Vec3(f32)) ?Physics.Ray.Hit {
    return Physics.Ray.cast(physics, start, translation);
}

fn dropTeleporterReward(self: *World, reward: shared.Item.Kind) void {
    const teleporter = self.getPtr(self.teleporter_id) orelse return;
    const teleporter_up = shared.Planet.up(teleporter.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
    _ = self.spawn(.{
        .kind = .item_pickup,
        .item = reward,
        .transform = .{
            .position = teleporter.transform.position + nz.vec.scale(teleporter_up, 10),
            .rotation = teleporter.transform.rotation,
        },
        .spawn_impulse = shared.Planet.surfaceLaunch(
            teleporter.transform.position,
            nz.vec.randomUnitVector(nz.Vec3(f32), self.prng.random()),
            item_launch_angle,
            item_throw_speed,
        ),
    }) catch {};
}

pub fn flush(self: *World, physics: *Physics) !void {
    for (self.new_spawns.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (entity.kind.collider() != null) try physics.createBody(entity);
        self.spawned.appendAssumeCapacity(id);
    }
    self.new_spawns.clearRetainingCapacity();

    var currency_reward: u32 = 0;
    for (self.pending_despawns.items) |despawn| {
        const entity = self.getPtrRaw(despawn.id) orelse continue;

        if (entity.body_id) |body_id| {
            physics.destroyBody(body_id);
            entity.body_id = null;
        }
        if (entity.kind == .player and !despawn.remove) {
            entity.replicated_velocity = .{ 0, 0, 0 };
            continue;
        } else {
            if (std.mem.indexOfScalar(shared.entity.Id, self.players.items, despawn.id)) |player_index| {
                _ = self.players.swapRemove(player_index);
            }
            if (entity.kind == .enemy) currency_reward += entity.currency;
            if (std.mem.indexOfScalar(shared.entity.Id, self.teleport_bosses.items, despawn.id)) |boss_index| {
                _ = self.teleport_bosses.swapRemove(boss_index);
                if (self.teleport_bosses.items.len == 0) self.dropTeleporterReward(.lightning);
            }
            _ = self.entities.swapRemove(despawn.id);
        }
        self.client_updates.appendAssumeCapacity(.{ .despawn_entity = .{ .id = despawn.id } });
    }
    if (currency_reward > 0) for (self.players.items) |player_id| {
        const player = self.getPtrRaw(player_id) orelse continue;
        player.currency += currency_reward;
        self.client_updates.appendAssumeCapacity(.{ .set_currency = .{ .amount = player.currency, .id = player_id } });
    };

    self.pending_despawns.clearRetainingCapacity();
}
