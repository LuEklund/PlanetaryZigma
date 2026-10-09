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

    if (director.spawning) {
        if (world.elapsed_time - director.last_salary >= 1.0) {
            director.last_salary = world.elapsed_time;
            director.credits += director.salary_per_second * shared.difficulty.directorCreditScale(world.difficultyCoefficient(), world.players.items.len);
        }
        const random = world.prng.random();
        const enemy_kind = shared.Biome.forRadius(world.planet.planet_radius).pickEnemy(random) orelse return;
        const enemy_spec = shared.entity.Kind.spec(.{ .enemy = enemy_kind });
        const difficulty_coefficient = world.difficultyCoefficient();
        const pack_size: f32 = @floatFromInt(enemy_spec.pack_size);
        const base_cost: f32 = @as(f32, @floatFromInt(enemy_spec.currency)) * pack_size;
        const wants_elite = difficulty_coefficient >= shared.Elite.min_coefficient and random.float(f32) < shared.Elite.chance;
        const elite: shared.Elite.Kind = if (wants_elite) shared.Elite.roll(random) else .none;
        const cost = base_cost * shared.Elite.get(elite).cost_multiplier;
        if (director.credits >= cost) {
            const player_index = random.uintLessThan(usize, world.players.items.len);
            if (world.getPtr(world.players.items[player_index])) |player| {
                const surface = world.planet.surfacePointNear(player.transform.position, enemy_min_spawn_distance, enemy_max_spawn_distance + 30, random);
                const spawn_up = nz.vec.normalize(surface);
                var spawned_any = false;
                for (0..enemy_spec.pack_size) |pack_index| {
                    const pack_offset: nz.Vec3(f32) = if (pack_index == 0) .{ 0, 0, 0 } else nz.vec.scale(nz.vec.randomUnitVector(nz.Vec3(f32), random), 2.5);
                    const position = surface + nz.vec.scale(spawn_up, 2) + pack_offset - nz.vec.scale(spawn_up, nz.vec.dot(pack_offset, spawn_up));
                    if (world.spawn(.{
                        .kind = .{ .enemy = enemy_kind },
                        .elite = elite,
                        .transform = .{ .position = position },
                        .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
                    })) |_| {
                        spawned_any = true;
                    } else |_| break;
                }
                if (spawned_any) director.credits -= cost;
            }
        }
    }
}
