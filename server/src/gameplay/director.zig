//! Enemy spending like Risk of Rain 2 (decision 0014): credit-earning combat directors that
//! spawn in waves, a teleporter boss director, and a scene director run once per stage.
const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const World = @import("../World.zig");
const Director = World.Director;
const EnemyKind = shared.entity.EnemyKind;
const Category = shared.entity.Category;

const enemy_max_spawn_distance: f32 = 85;
const enemy_min_spawn_distance: f32 = enemy_max_spawn_distance * 0.8;
const map_monster_cap: usize = 40;
const max_per_wave: u8 = 5;
const boss_max_spawns: u8 = 6;
const too_cheap_factor: f32 = 6;
const elite_tier_cost: f32 = 6;
const handover_fraction: f32 = 0.4;
const boss_base_credits: f32 = 600;
const scene_interactable_credits: f32 = 220;
const scene_monster_credits: f32 = 100;
const shrine_combat_credits: f32 = 100;

/// RoR2 interactable spawn cards: scene credits cost and weight.
const InteractableCard = struct { kind: shared.entity.Kind, cost: f32, weight: u32 };
const interactable_cards = [_]InteractableCard{
    .{ .kind = .lootbox, .cost = 15, .weight = 24 },
    .{ .kind = .barrel, .cost = 1, .weight = 10 },
    .{ .kind = .shrine_chance, .cost = 20, .weight = 4 },
    .{ .kind = .shrine_combat, .cost = 20, .weight = 3 },
    .{ .kind = .shrine_mountain, .cost = 20, .weight = 3 },
};
const scene_min_player_distance: f32 = 60;

const Tuning = struct {
    credit_multiplier: f32,
    wave_interval: [2]f32,
    rest_interval: [2]f32,
    instant: bool = false,
};

const tunings: std.EnumArray(Director.Kind, Tuning) = .init(.{
    .fast = .{ .credit_multiplier = 0.75, .wave_interval = .{ 0.1, 1 }, .rest_interval = .{ 4.5, 9 } },
    .slow = .{ .credit_multiplier = 0.75, .wave_interval = .{ 0.1, 1 }, .rest_interval = .{ 22.5, 30 } },
    .teleporter = .{ .credit_multiplier = 2, .wave_interval = .{ 0.5, 0.5 }, .rest_interval = .{ 2, 4 } },
    .teleporter_boss = .{ .credit_multiplier = 0, .wave_interval = .{ 0.1, 0.3 }, .rest_interval = .{ 0, 0 }, .instant = true },
    .shrine = .{ .credit_multiplier = 0, .wave_interval = .{ 0.1, 0.4 }, .rest_interval = .{ 0, 0 }, .instant = true },
});

/// RoR2 family event: for a whole stage only one family spawns, announced at stage start.
pub const Family = struct {
    name: []const u8,
    members: []const EnemyKind,
    announcement: []const u8,
};

pub const families = [_]Family{
    .{ .name = "tubloid", .members = &.{ .tubloid, .tubloida, .hunkloid }, .announcement = "Something stirs in the tubes below." },
    .{ .name = "grass", .members = &.{ .grass1, .grass_tank, .acorn }, .announcement = "The grass begins to whisper." },
    .{ .name = "bloop", .members = &.{ .blooploid, .wisp, .bloorp_lord }, .announcement = "The air hums and bubbles." },
    .{ .name = "swarm", .members = &.{ .mite, .bomber, .spitter }, .announcement = "The ground crawls with tiny legs." },
};
const family_chance: f32 = 0.02;

const category_weights: std.EnumArray(Category, u32) = .init(.{ .basic = 4, .miniboss = 2, .champion = 1 });

pub fn updateRunTimer(world: *World) void {
    const previous_second = @floor(world.run_seconds);
    world.run_seconds += world.delta_time;
    if (@floor(world.run_seconds) == previous_second) return;
    const difficulty_coefficient = world.difficultyCoefficient();
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .difficulty = .{
        .run_seconds = world.run_seconds,
        .coefficient = difficulty_coefficient,
        .level = shared.difficulty.level(difficulty_coefficient, world.players.items.len),
    } } });
}

/// Stage start: fast + slow directors on, then the scene director spends once.
pub fn startStage(world: *World) !void {
    world.directors = .initFill(.{});
    world.directors.getPtr(.fast).active = true;
    world.directors.getPtr(.slow).active = true;
    world.mountain_stacks = 0;
    const random = world.prng.random();
    world.family = if (random.float(f32) < family_chance) random.uintLessThan(u8, families.len) else null;
    if (world.family) |family| announceFamily(world, family);
    try populateScene(world);
}

/// Teleporter activated: fast + slow hand 40% of their credits to the teleporter director;
/// the boss director gets its one-off budget.
pub fn startTeleporterEvent(world: *World) void {
    var handover: f32 = 0;
    for ([_]Director.Kind{ .fast, .slow }) |kind| {
        const director = world.directors.getPtr(kind);
        handover += director.credits * handover_fraction;
        director.* = .{};
    }
    world.directors.set(.teleporter, .{ .active = true, .credits = handover });
    world.directors.set(.teleporter_boss, .{
        .active = true,
        .credits = boss_base_credits * @sqrt(world.difficultyCoefficient()) * (1 + @as(f32, @floatFromInt(world.mountain_stacks))),
    });
}

/// Everything but the boss director (RoR2 at 99% teleporter charge).
pub fn stopCombat(world: *World) void {
    for ([_]Director.Kind{ .fast, .slow, .teleporter }) |kind| world.directors.set(kind, .{});
}

pub fn announceFamily(world: *World, family: u8) void {
    const text = families[family].announcement;
    world.client_updates.appendAssumeCapacity(.{ .chat_message = .{
        .id = .none,
        .text_len = @intCast(text.len),
        .text = text,
    } });
}

fn cheapestCard() f32 {
    var cheapest: f32 = std.math.inf(f32);
    for (interactable_cards) |card| cheapest = @min(cheapest, card.cost);
    return cheapest;
}

/// RoR2 Shrine of Combat: an instant director with 100·coeff credits.
pub fn startShrineOfCombat(world: *World) void {
    world.directors.set(.shrine, .{ .active = true, .credits = shrine_combat_credits * world.difficultyCoefficient() });
}

pub fn stopAll(world: *World) void {
    world.directors = .initFill(.{});
}

pub fn update(world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    if (world.toggle_spawning_requested) {
        world.toggle_spawning_requested = false;
        world.spawning_enabled = !world.spawning_enabled;
        std.log.debug("dev: enemy spawning {s}", .{if (world.spawning_enabled) "on" else "off"});
    }
    if (world.players.items.len == 0 or !world.spawning_enabled) return;
    for (std.enums.values(Director.Kind)) |kind| {
        const director = world.directors.getPtr(kind);
        if (!director.active) continue;
        earn(world, director, tunings.get(kind));
        try step(world, director, kind);
    }
}

fn earn(world: *const World, director: *Director, tuning: Tuning) void {
    const players: f32 = @floatFromInt(world.players.items.len);
    const per_second = tuning.credit_multiplier * (1 + 0.4 * world.difficultyCoefficient()) * (players + 1) / 2;
    director.credits += per_second * world.delta_time;
}

fn step(world: *World, director: *Director, kind: Director.Kind) !void {
    director.timer -= world.delta_time;
    if (director.timer > 0) return;
    const tuning = tunings.get(kind);
    const random = world.prng.random();
    if (try spawnFromWave(world, director, kind, random)) {
        director.timer = between(random, tuning.wave_interval);
        return;
    }
    director.wave = null;
    if (tuning.instant and director.spawned_any) {
        director.active = false;
        return;
    }
    director.timer = between(random, tuning.rest_interval);
}

/// One RoR2 spawn attempt. False ends the wave (cap hit, can't afford, too cheap, wave full).
fn spawnFromWave(world: *World, director: *Director, kind: Director.Kind, random: std.Random) !bool {
    const is_boss = kind == .teleporter_boss;
    const instant = tunings.get(kind).instant;
    if (!is_boss and world.enemyCount() >= map_monster_cap) return false;
    const biome = spawnPool(world);
    if (director.wave == null) {
        const enemy = (if (is_boss) pickBossCard(&biome, director.credits, random) else pickCard(&biome, random)) orelse return false;
        director.wave = .{ .enemy = enemy, .elite = pickElite(enemy, director.credits, random), .spawned = 0 };
    }
    const wave = &director.wave.?;
    const limit = if (instant) boss_max_spawns else max_per_wave;
    if (wave.spawned >= limit) return false;
    const cost = cardCost(wave.enemy, wave.elite);
    if (director.credits < cost) return false;
    if (!instant and tooCheap(&biome, wave.enemy, cost, director.credits)) return false;

    const near = if (is_boss) teleporterPosition(world) orelse return false else targetPlayer(world, random) orelse return false;
    const distance: [2]f32 = if (is_boss) .{ 15, 25 } else .{ enemy_min_spawn_distance, enemy_max_spawn_distance + 30 };
    if (!spawnPack(world, wave.enemy, wave.elite, near, distance, is_boss)) return false;
    director.credits -= cost;
    director.spawned_any = true;
    wave.spawned += 1;
    return true;
}

/// The biome's monster weights, or only the family's members during a family event.
fn spawnPool(world: *const World) shared.Biome {
    var pool = shared.Biome.forRadius(world.planet.planet_radius).*;
    const stages_done = world.stage -| 1;
    for (std.enums.values(EnemyKind)) |enemy| {
        if (spec(enemy).min_stage > stages_done) pool.enemy_weights.set(enemy, 0);
    }
    const family = world.family orelse return pool;
    pool.enemy_weights = .initFill(0);
    for (families[family].members) |member| pool.enemy_weights.set(member, 1);
    return pool;
}

/// RoR2: a card is too cheap when credits exceed 6× its cost and a pricier card exists.
fn tooCheap(biome: *const shared.Biome, enemy: EnemyKind, cost: f32, credits: f32) bool {
    if (credits <= too_cheap_factor * cost) return false;
    return baseCost(enemy) < mostExpensive(biome);
}

fn mostExpensive(biome: *const shared.Biome) f32 {
    var highest: f32 = 0;
    for (std.enums.values(EnemyKind)) |enemy| {
        if (biome.enemy_weights.get(enemy) == 0) continue;
        highest = @max(highest, baseCost(enemy));
    }
    return highest;
}

fn pickCard(biome: *const shared.Biome, random: std.Random) ?EnemyKind {
    var category_total: u32 = 0;
    for (std.enums.values(Category)) |category| {
        if (poolWeight(biome, category) > 0) category_total += category_weights.get(category);
    }
    if (category_total == 0) return null;
    var roll = random.uintLessThan(u32, category_total);
    for (std.enums.values(Category)) |category| {
        if (poolWeight(biome, category) == 0) continue;
        const weight = category_weights.get(category);
        if (roll < weight) return pickInCategory(biome, category, random);
        roll -= weight;
    }
    unreachable;
}

/// Champions first; if none is affordable, any monster (RoR2's "Horde of Many").
fn pickBossCard(biome: *const shared.Biome, credits: f32, random: std.Random) ?EnemyKind {
    if (pickInCategory(biome, .champion, random)) |champion| {
        if (baseCost(champion) <= credits) return champion;
    }
    for (0..16) |_| {
        const enemy = pickCard(biome, random) orelse return null;
        if (baseCost(enemy) <= credits) return enemy;
    }
    return null;
}

fn poolWeight(biome: *const shared.Biome, category: Category) u32 {
    var total: u32 = 0;
    for (std.enums.values(EnemyKind)) |enemy| {
        if (spec(enemy).category == category) total += biome.enemy_weights.get(enemy);
    }
    return total;
}

fn pickInCategory(biome: *const shared.Biome, category: Category, random: std.Random) ?EnemyKind {
    const total = poolWeight(biome, category);
    if (total == 0) return null;
    var roll = random.uintLessThan(u32, total);
    for (std.enums.values(EnemyKind)) |enemy| {
        if (spec(enemy).category != category) continue;
        const weight = biome.enemy_weights.get(enemy);
        if (roll < weight) return enemy;
        roll -= weight;
    }
    unreachable;
}

/// Elite whenever the director can afford the ×6 tier.
fn pickElite(enemy: EnemyKind, credits: f32, random: std.Random) shared.Elite.Kind {
    if (credits < baseCost(enemy) * elite_tier_cost) return .none;
    return shared.Elite.roll(random);
}

fn spec(enemy: EnemyKind) *const shared.entity.Spec {
    return shared.entity.Kind.spec(.{ .enemy = enemy });
}

fn baseCost(enemy: EnemyKind) f32 {
    const card = spec(enemy);
    return @as(f32, @floatFromInt(card.currency)) * @as(f32, @floatFromInt(card.pack_size));
}

fn cardCost(enemy: EnemyKind, elite: shared.Elite.Kind) f32 {
    return baseCost(enemy) * shared.Elite.get(elite).cost_multiplier;
}

fn between(random: std.Random, range: [2]f32) f32 {
    return range[0] + random.float(f32) * (range[1] - range[0]);
}

fn targetPlayer(world: *World, random: std.Random) ?nz.Vec3(f32) {
    const index = random.uintLessThan(usize, world.players.items.len);
    const player = world.getPtr(world.players.items[index]) orelse return null;
    return player.transform.position;
}

fn teleporterPosition(world: *World) ?nz.Vec3(f32) {
    const teleporter = world.getPtr(world.teleporter_id) orelse return null;
    return teleporter.transform.position;
}

/// Spawns a pack around a surface point `distance` away from `near`. True when any spawned.
fn spawnPack(
    world: *World,
    enemy: EnemyKind,
    elite: shared.Elite.Kind,
    near: nz.Vec3(f32),
    distance: [2]f32,
    is_boss: bool,
) bool {
    const random = world.prng.random();
    const surface = world.planet.surfacePointNear(near, distance[0], distance[1], random);
    return spawnPackAt(world, enemy, elite, surface, is_boss);
}

fn spawnPackAt(world: *World, enemy: EnemyKind, elite: shared.Elite.Kind, surface: nz.Vec3(f32), is_boss: bool) bool {
    const random = world.prng.random();
    const up = shared.Planet.surfaceUp(surface);
    const lift: f32 = if (is_boss) 3 else 2;
    var spawned_any = false;
    for (0..spec(enemy).pack_size) |pack_index| {
        const scatter = if (pack_index == 0)
            nz.Vec3(f32){ 0, 0, 0 }
        else
            nz.vec.scale(nz.vec.randomUnitVector(nz.Vec3(f32), random), 2.5);
        const position = surface + nz.vec.scale(up, lift) + shared.math.projectOnPlane(scatter, up);
        _ = world.spawn(.{
            .kind = .{ .enemy = enemy },
            .elite = elite,
            .transform = .{ .position = position },
            .flags = .{ .is_teleporter_boss = is_boss },
            .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
        }) catch break;
        spawned_any = true;
    }
    return spawned_any;
}

/// RoR2 scene director: chests from interactable credits, then idle monsters spread over the
/// planet away from players from monster credits.
fn populateScene(world: *World) !void {
    const random = world.prng.random();
    const players: f32 = @floatFromInt(@max(world.players.items.len, 1));
    var interactable_credits = scene_interactable_credits * (1 + 0.5 * (players - 1));
    var total_weight: u32 = 0;
    for (interactable_cards) |card| total_weight += card.weight;
    while (interactable_credits >= cheapestCard()) {
        var roll = random.uintLessThan(u32, total_weight);
        const card = for (interactable_cards) |candidate| {
            if (roll < candidate.weight) break candidate;
            roll -= candidate.weight;
        } else unreachable;
        if (card.cost > interactable_credits) continue;
        interactable_credits -= card.cost;
        const direction = if (world.dev_mode)
            nz.vec.normalize(world.planet.surfacePointNear(teleporterPosition(world) orelse .{ 0, 1, 0 }, 5, 12, random))
        else
            nz.vec.randomUnitVector(nz.Vec3(f32), random);
        _ = try world.spawn(.{ .kind = card.kind, .transform = world.planet.surfaceTransform(direction, 0.2) });
    }

    const biome = spawnPool(world);
    var monster_credits = scene_monster_credits * world.difficultyCoefficient();
    var attempts: usize = 0;
    while (attempts < 64 and world.enemyCount() < map_monster_cap) : (attempts += 1) {
        const enemy = pickCard(&biome, random) orelse return;
        const cost = baseCost(enemy);
        if (cost > monster_credits) continue;
        const surface = world.planet.surfacePoint(nz.vec.randomUnitVector(nz.Vec3(f32), random));
        if (nearPlayer(world, surface)) continue;
        if (spawnPackAt(world, enemy, .none, surface, false)) monster_credits -= cost;
    }
}

fn nearPlayer(world: *World, position: nz.Vec3(f32)) bool {
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        if (nz.vec.distance(player.transform.position, position) < scene_min_player_distance) return true;
    }
    return false;
}
