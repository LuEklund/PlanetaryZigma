const World = @This();

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const Physics = @import("system/Physics.zig");
const Navmesh = @import("system/Navmesh.zig");
const nz = shared.numz;

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity),
players: std.ArrayList(shared.entity.Id),
teleport_bosses: std.ArrayList(shared.entity.Id),
new_spawns: std.ArrayList(shared.entity.Id),
pending_despawns: std.ArrayList(PendingDespawn),
planet: shared.Planet,
navmesh: Navmesh,
physics: *Physics,
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
    credits: u32,
    salary_per_second: u32,
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

    un_stun_at: f32 = 0,

    last_used: std.EnumArray(shared.entity.Action, f32) = .initFill(0),
    last_interact: f32 = 0,
    mode: Mode = .falling,

    pub fn stat(self: *const Entity, stat_kind: shared.Item.Stat) f32 {
        return shared.Item.Stat.value(stat_kind, &self.kind.spec().base_stats, self.inventory);
    }

    pub const Mode = enum {
        walking,
        falling,
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
        .gpa = gpa,
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
        .physics = undefined,
        .options = .{ .draw_flow_field = true, .draw_chunk_borders = true },
        .place = .ship,
        .director = .{ .credits = 0, .salary_per_second = 2, .last_salary = 0, .spawning = false },
        .next_entity_id = 1,
        .stage = 0,
        .prng = .init(0xACE1),
        .elapsed_time = 0,
        .delta_time = 0,
        .tick = 0,
    };
}

pub fn deinit(self: *World) void {
    self.entities.deinit(self.gpa);
    self.players.deinit(self.gpa);
    self.teleport_bosses.deinit(self.gpa);
    self.new_spawns.deinit(self.gpa);
    self.pending_despawns.deinit(self.gpa);
    self.client_updates.deinit(self.gpa);
    self.spawned.deinit(self.gpa);
    self.physics_commands.deinit(self.gpa);
    self.impacts.deinit(self.gpa);
    self.planet.deinit(self.gpa);
    self.navmesh.deinit(self.gpa);
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
    entity.max_health = entity.stat(.health);
    if (entity.kind == .enemy) {
        entity.max_health *= @as(f32, @floatFromInt(self.stage));
    }
    entity.health = entity.max_health;
    entity.currency = entity.kind.spec().currency;
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

pub fn rayCast(self: *World, start: nz.Vec3(f32), translation: nz.Vec3(f32)) ?Physics.Ray.Hit {
    return Physics.Ray.cast(self.physics, start, translation);
}

pub fn giveItem(self: *World, player: *Entity, item: shared.Item.Kind, count: u8) ?u8 {
    if (player.inventory.get(item) >= 255) return null;
    const item_count = player.inventory.add(item, count);
    const old_max_health = player.max_health;
    player.max_health = player.stat(.health);
    player.health = @min(player.max_health, player.health + @max(0, player.max_health - old_max_health));
    self.client_updates.appendAssumeCapacity(.{ .inventory = .{
        .id = player.id,
        .item_kind = item,
        .set = item_count,
    } });
    self.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_max = @floatCast(player.max_health) } } });
    self.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_current = @floatCast(player.health) } } });
    return item_count;
}

pub const HealthChange = enum { ignored, changed, killed };

pub fn removeHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (entity.flags.is_dead or entity.max_health <= 0) return .ignored;
    if (entity.flags.invincible and amount > 0) return .ignored;
    const random = self.prng.random();
    var new_amount = (random.float(f32) - 0.5) * 0.5 * amount + amount;
    new_amount = @min(new_amount, amount);
    if (source) |source_entity| {
        if (random.float(f32) < source_entity.stat(.critical_chance)) new_amount *= 2;

        if (random.float(f32) < entity.stat(.block_chance)) new_amount = 0;

        if (random.float(f32) < source_entity.stat(.stun_chance)) {
            const stun_duration: f32 = 2;
            entity.un_stun_at = self.elapsed_time + stun_duration;
            self.client_updates.appendAssumeCapacity(.{ .event = .{ .stun = .{ .id = entity.id, .duration = stun_duration } } });
        }
    }
    return self.addHealth(entity, -new_amount, source);
}

pub fn addHealth(self: *World, entity: *Entity, amount: f32, source: ?*const Entity) HealthChange {
    if (entity.max_health <= 0) return .ignored;
    const before = entity.health;
    if (before <= 0) return .ignored;
    var current = @min(entity.max_health, entity.health + amount);
    entity.health = current;
    if (current == before) return .ignored;
    if (current <= 0 and entity.kind == .target_dummy) {
        current = entity.max_health;
        entity.health = current;
        self.client_updates.appendAssumeCapacity(.{ .health = .{
            .id = entity.id,
            .source = if (source) |source_entity| source_entity.id else .none,
            .amount = .{ .set_current = @floatCast(current) },
        } });
        return .changed;
    }
    if (current <= 0) self.queueDespawn(entity.id);

    self.client_updates.appendAssumeCapacity(.{ .health = .{
        .id = entity.id,
        .source = if (source) |source_entity| source_entity.id else .none,
        .amount = .{ .set_current = @floatCast(current) },
    } });
    return if (current <= 0) .killed else .changed;
}

pub fn ready(entity: *const Entity, action: shared.entity.Action, now: f32) bool {
    return now - entity.last_used.get(action) >= entity.stat(action.cooldownStat());
}

pub const Outcome = enum { fired, on_cooldown, out_of_range };

pub fn useAction(world: *World, attacker: *Entity, potential_target: ?*const Entity, action: shared.entity.Action) Outcome {
    if (!ready(attacker, action, world.elapsed_time)) return .on_cooldown;

    const assigned = attacker.kind.spec().skills.get(action) orelse return .out_of_range;
    if (potential_target) |target| {
        const distance = nz.vec.distance(attacker.transform.position, target.transform.position);
        if (distance >= assigned.range) return .out_of_range;
    }

    attacker.last_used.set(action, world.elapsed_time);
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .action = .{ .id = attacker.id, .action = action, .skill = assigned.skill } } });
    return .fired;
}

pub const aim_range: f32 = 300;
const rocket_speed: f32 = 65;
const bullet_speed: f32 = 100;
const rocket_lifetime: f32 = 2.5;
const bullet_lifetime: f32 = 1;

pub fn executeSkill(world: *World, caster: *Entity, target: ?*Entity, skill: shared.entity.Skill) !void {
    const planet_up = shared.Planet.up(caster.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
    switch (skill) {
        .shoot => {
            //TODO: muzzle socket per model; every skill assumes position + up * 0.8.
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const start_direction = if (target) |target_entity|
                nz.vec.normalize(target_entity.transform.position - muzzle_position)
            else if (caster.kind == .player) direction: {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
                const aim_point = aimPoint(world, caster.transform.position, caster.controller.input.camera_position, camera_forward);
                break :direction nz.vec.normalize(aim_point - muzzle_position);
            } else nz.vec.normalize(caster.transform.forward());
            const rocket_chance = caster.stat(.rocket_chance);
            const fires_rocket = rocket_chance > 0 and world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            _ = try world.spawn(.{
                .kind = switch (projectile_kind) {
                    .cube => .projectile_cube,
                    .rocket => .projectile_rocket,
                },
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(start_direction, 1.0),
                    .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                },
                .replicated_velocity = nz.vec.scale(start_direction, if (fires_rocket) rocket_speed else bullet_speed),
                .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
                .damage = caster.stat(.damage),
            });
        },
        .spread_shot => {
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            var start_direction: nz.Vec3(f32) = undefined;
            var spread_right: nz.Vec3(f32) = undefined;
            var spread_up: nz.Vec3(f32) = undefined;
            if (target == null and caster.kind == .player) {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
                const aim_point = aimPoint(world, caster.transform.position, caster.controller.input.camera_position, camera_forward);
                start_direction = nz.vec.normalize(aim_point - muzzle_position);
                spread_right = nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
                spread_up = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 1, 0 }));
            } else {
                start_direction = if (target) |target_entity|
                    nz.vec.normalize(target_entity.transform.position - muzzle_position)
                else
                    nz.vec.normalize(caster.transform.forward());
                spread_right = nz.vec.normalize(nz.vec.cross(start_direction, planet_up));
                spread_up = nz.vec.cross(spread_right, start_direction);
            }
            const rocket_chance = caster.stat(.rocket_chance);
            const fires_rocket = rocket_chance > 0 and world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            for (0..10) |_| {
                const theta = world.prng.random().float(f32) * std.math.tau;
                const spread = world.prng.random().float(f32) * 0.1;
                const off_set = nz.vec.scale(spread_right, @cos(theta) * spread) + nz.vec.scale(spread_up, @sin(theta) * spread);
                _ = try world.spawn(.{
                    .kind = switch (projectile_kind) {
                        .cube => .projectile_cube,
                        .rocket => .projectile_rocket,
                    },
                    .owner_id = caster.id,
                    .transform = .{
                        .position = muzzle_position + nz.vec.scale(start_direction, 1.0),
                        .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                    },
                    .replicated_velocity = nz.vec.scale(start_direction + off_set, if (fires_rocket) rocket_speed else bullet_speed),
                    .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
                    .damage = caster.stat(.damage),
                    .flags = .{ .invincible = true },
                });
            }
        },
        .dash => {
            const forward = if (target) |target_entity|
                nz.vec.normalize(target_entity.transform.position - caster.transform.position)
            else if (caster.kind == .player) camera: {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                break :camera nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
            } else nz.vec.normalize(caster.transform.forward());
            const fwd_proj = forward - nz.vec.scale(planet_up, nz.vec.dot(forward, planet_up));
            world.physics_commands.appendAssumeCapacity(.{
                .verb = .{ .teleport = caster.transform.position + nz.vec.scale(fwd_proj, 2 * caster.stat(.speed)) },
                .id = caster.id,
            });
        },
        .use_equipment => {
            const effect = shared.Item.equippedEffect(caster.inventory) orelse return;
            switch (effect) {
                .freeze_world => world.world_unstun_at = world.elapsed_time + 10,
            }
        },
        .shoot_cube => {
            const target_entity = target orelse return;
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_dir = nz.vec.normalize(target_entity.transform.position - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_cube,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                    .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                },
                .replicated_velocity = nz.vec.scale(aim_dir, 50),
                .lifetime = 2,
                .damage = caster.stat(.damage),
            });
        },
        .heal => {
            const target_entity = target orelse return;
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_dir = nz.vec.normalize(target_entity.transform.position - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_heal,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                    .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                },
                .replicated_velocity = nz.vec.scale(aim_dir, 50),
                .lifetime = 2,
                .damage = caster.stat(.damage),
            });
        },
        .melee => {
            const target_entity = target orelse return;
            _ = world.removeHealth(target_entity, caster.stat(.damage), caster);
        },
        .arc_jump => {
            const target_entity = target orelse return;
            world.act(.{ .id = caster.id, .verb = .{ .arc_jump = target_entity.transform.position } });
        },
        .plant => {},
    }
}

fn aimPoint(world: *World, player_position: nz.Vec3(f32), camera_position: nz.Vec3(f32), camera_forward: nz.Vec3(f32)) nz.Vec3(f32) {
    const player_depth = nz.vec.dot(player_position - camera_position, camera_forward);
    const ray_start = camera_position + nz.vec.scale(camera_forward, player_depth);
    const translation = nz.vec.scale(camera_forward, aim_range);
    const entity_distance: f32 = if (world.rayCast(ray_start, translation)) |hit| nz.vec.length(hit.point - ray_start) else aim_range;

    var terrain_distance: f32 = aim_range;
    var traveled: f32 = 0;
    for (0..128) |_| {
        const sample = ray_start + nz.vec.scale(camera_forward, traveled);
        const distance = world.planet.sample(sample);
        if (distance < 0.05) {
            terrain_distance = traveled;
            break;
        }
        traveled += @max(distance * 0.5, 0.05);
        if (traveled >= aim_range) break;
    }
    return ray_start + nz.vec.scale(camera_forward, @min(entity_distance, terrain_distance));
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

pub fn shipRoomPosition(self: *const World) nz.Vec3(f32) {
    return nz.Vec3(f32){ 0, self.planet.radiusFloat() * ship_room_altitude_factor, 0 };
}

pub fn playerSpawnPosition(self: *const World) nz.Vec3(f32) {
    return switch (self.place) {
        .ship => self.shipRoomPosition() + nz.Vec3(f32){ 0, ship_room_stand_height, 0 },
        .planet => self.planet.surfacePoint(.{ 0, 1, 0 }) + nz.Vec3(f32){ 0, 2, 0 },
    };
}

pub fn loadPlace(self: *World, place: Place) !void {
    self.place = place;
    for (self.entities.values()) |entry| {
        if (entry.kind != .player) self.queueDespawn(entry.id);
    }
    try self.flush();
    const random = self.prng.random();
    self.teleporter_id = .none;
    if (place == .planet) self.stage += 1;
    const spawn_planet_radius: u32 = switch (place) {
        .ship => ship_planet_radius,
        .planet => if (self.dev_mode)
            random.intRangeAtMost(u32, shared.Planet.dev_radius_min, shared.Planet.dev_radius_min + 1)
        else
            shared.Planet.radius_min + (self.stage - 1) * 9,
    };
    self.client_updates.appendAssumeCapacity(.{ .event = .{ .new_stage = self.stage } });
    self.client_updates.appendAssumeCapacity(.{ .spawn_planet = spawn_planet_radius });
    std.log.info("loadPlace {s} planet_radius={d}", .{ @tagName(place), spawn_planet_radius });
    try self.planet.sync(self.gpa, spawn_planet_radius);
    try self.flush();

    switch (place) {
        .ship => {
            const floor_position: nz.Vec3(f32) = self.shipRoomPosition();
            _ = try self.spawn(.{
                .kind = .platform,
                .transform = .{ .position = floor_position },
            });
            const slab: shared.entity.ColliderShape.HalfBoxExtent = shared.entity.Kind.collider(.platform).?.shape.box;
            const wall_center: nz.Vec3(f32) = floor_position + nz.Vec3(f32){ 0, slab.x, 0 };
            const wall_distance: f32 = slab.x + slab.y;
            const walls: [4]struct { offset: nz.Vec3(f32), axis: nz.Vec3(f32) } = .{
                .{ .offset = .{ wall_distance, 0, 0 }, .axis = .{ 0, 0, 1 } },
                .{ .offset = .{ -wall_distance, 0, 0 }, .axis = .{ 0, 0, 1 } },
                .{ .offset = .{ 0, 0, wall_distance }, .axis = .{ 1, 0, 0 } },
                .{ .offset = .{ 0, 0, -wall_distance }, .axis = .{ 1, 0, 0 } },
            };
            for (walls) |wall| {
                _ = try self.spawn(.{
                    .kind = .platform,
                    .transform = .{
                        .position = wall_center + wall.offset,
                        .rotation = nz.quat.Hamiltonian(f32).angleAxis(std.math.pi / 2.0, wall.axis),
                    },
                });
            }

            const dummy_capsule = shared.entity.Kind.collider(.target_dummy).?.shape.capsule;
            _ = try self.spawn(.{
                .kind = .target_dummy,
                .transform = .{ .position = floor_position + nz.Vec3(f32){
                    slab.x * 0.5,
                    slab.y + dummy_capsule.half_height + dummy_capsule.radius,
                    0,
                } },
            });

            const portal = try self.spawn(.{
                .kind = .teleporter,
                .transform = .{ .position = floor_position + nz.Vec3(f32){ 0, slab.y, 0 } },
            });
            portal.teleporter.state = .completed;
            portal.teleporter.charged = portal.teleporter.max_charge;
            self.teleporter_id = portal.id;
            try self.flush();
        },
        .planet => {
            self.director.spawning = true;
            const teleporter_direction = if (self.dev_mode)
                nz.Vec3(f32){ 0, 1, 0 }
            else
                nz.vec.randomUnitVector(nz.Vec3(f32), random);
            const teleporter_position = self.planet.surfacePoint(teleporter_direction);
            for (0..25) |_| {
                const vector_direction = if (self.dev_mode)
                    nz.vec.normalize(self.planet.surfacePointNear(teleporter_position, 5, 10, random))
                else
                    nz.vec.randomUnitVector(nz.Vec3(f32), random);
                const transform = self.planet.surfaceTransform(vector_direction, 0.2);
                _ = try self.spawn(.{
                    .kind = .lootbox,
                    .transform = transform,
                });
            }

            const teleporter = try self.spawn(.{
                .kind = .teleporter,
                .transform = .{ .position = teleporter_position },
            });
            const teleport_planet_up = nz.vec.normalize(teleporter_position);
            const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
            const dot = std.math.clamp(nz.vec.dot(default_up, teleport_planet_up), -1.0, 1.0);
            teleporter.transform.rotation = if (dot < 0.9999) blk: {
                const axis = if (dot > -0.9999)
                    nz.vec.normalize(nz.vec.cross(default_up, teleport_planet_up))
                else
                    nz.Vec3(f32){ 1, 0, 0 };
                break :blk nz.quat.Hamiltonian(f32).angleAxis(std.math.acos(dot), axis);
            } else .identity;
            self.teleporter_id = teleporter.id;
        },
    }

    const player_spawn_position = self.playerSpawnPosition();
    for (self.entities.values()) |*player| {
        if (player.kind != .player) continue;
        player.transform.position = player_spawn_position;
        player.replicated_velocity = .{ 0, 0, 0 };
        if (player.flags.is_dead) {
            player.flags.is_dead = false;
            player.health = player.max_health;
            try self.physics.createBody(player);
            self.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_current = @floatCast(player.max_health) } } });
        } else {
            self.act(.{ .id = player.id, .verb = .{ .teleport = player_spawn_position } });
            self.act(.{ .id = player.id, .verb = .{ .set_velocity = .{ 0, 0, 0 } } });
        }
    }
}

pub fn flush(self: *World) !void {
    for (self.new_spawns.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (entity.kind.collider() != null) try self.physics.createBody(entity);
        self.spawned.appendAssumeCapacity(id);
    }
    self.new_spawns.clearRetainingCapacity();

    var currency_reward: u32 = 0;
    for (self.pending_despawns.items) |despawn| {
        const entity = self.getPtrRaw(despawn.id) orelse continue;

        if (entity.body_id) |body_id| {
            self.physics.destroyBody(body_id);
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
