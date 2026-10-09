const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const World = @import("../World.zig");

const enemy_max_spawn_distance: f32 = 85;
const enemy_min_spawn_distance: f32 = enemy_max_spawn_distance * 0.8;
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

pub fn updateDirector(world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (world.players.items.len == 0) return;
    const director = &world.director;
    if (world.toggle_spawning_requested) {
        world.toggle_spawning_requested = false;
        director.spawning = !director.spawning;
        std.log.debug("dev: enemy spawning {s}", .{if (director.spawning) "on" else "off"});
    }
    if (!director.spawning) return;

    paySalary(world);
    const random = world.prng.random();
    const enemy_kind = shared.Biome.forRadius(world.planet.planet_radius).pickEnemy(random) orelse return;
    const elite = rollElite(world.difficultyCoefficient(), random);
    const cost = spawnCost(enemy_kind, elite);
    if (director.credits < cost) return;
    const player_index = random.uintLessThan(usize, world.players.items.len);
    const player = world.getPtr(world.players.items[player_index]) orelse return;
    if (spawnPack(world, enemy_kind, elite, player.transform.position)) director.credits -= cost;
}

fn paySalary(world: *World) void {
    const director = &world.director;
    if (world.elapsed_time - director.last_salary < 1.0) return;
    director.last_salary = world.elapsed_time;
    const scale = shared.difficulty.directorCreditScale(world.difficultyCoefficient(), world.players.items.len);
    director.credits += director.salary_per_second * scale;
}

fn rollElite(difficulty_coefficient: f32, random: std.Random) shared.Elite.Kind {
    if (difficulty_coefficient < shared.Elite.min_coefficient) return .none;
    if (random.float(f32) >= shared.Elite.chance) return .none;
    return shared.Elite.roll(random);
}

fn spawnCost(enemy_kind: shared.entity.EnemyKind, elite: shared.Elite.Kind) f32 {
    const spec = shared.entity.Kind.spec(.{ .enemy = enemy_kind });
    const pack_size: f32 = @floatFromInt(spec.pack_size);
    const base_cost = @as(f32, @floatFromInt(spec.currency)) * pack_size;
    return base_cost * shared.Elite.get(elite).cost_multiplier;
}

/// Spawns a pack near `near`. Returns true when at least one enemy spawned.
fn spawnPack(world: *World, enemy_kind: shared.entity.EnemyKind, elite: shared.Elite.Kind, near: nz.Vec3(f32)) bool {
    const random = world.prng.random();
    const spec = shared.entity.Kind.spec(.{ .enemy = enemy_kind });
    const max_distance = enemy_max_spawn_distance + 30;
    const surface = world.planet.surfacePointNear(near, enemy_min_spawn_distance, max_distance, random);
    const up = shared.Planet.surfaceUp(surface);
    var spawned_any = false;
    for (0..spec.pack_size) |pack_index| {
        const scatter = if (pack_index == 0)
            nz.Vec3(f32){ 0, 0, 0 }
        else
            nz.vec.scale(nz.vec.randomUnitVector(nz.Vec3(f32), random), 2.5);
        const position = surface + nz.vec.scale(up, 2) + shared.math.projectOnPlane(scatter, up);
        _ = world.spawn(.{
            .kind = .{ .enemy = enemy_kind },
            .elite = elite,
            .transform = .{ .position = position },
            .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
        }) catch break;
        spawned_any = true;
    }
    return spawned_any;
}
