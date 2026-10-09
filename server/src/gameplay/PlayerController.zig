const shared = @import("shared");
const system = @import("../System.zig");
const World = system.World;
const tracy = @import("ztracy");
const combat = @import("combat.zig");
const items = @import("items.zig");
const skills = @import("skills.zig");
const lobby = @import("lobby.zig");
const math = shared.math;
const nz = shared.numz;

const interact_cooldown: f32 = 0.3;

const Frame = struct {
    planet_up: nz.Vec3(f32),
    camera_forward: nz.Vec3(f32),
    move_forward: nz.Vec3(f32),
};

pub fn update(world: *World, physics: *system.Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        const frame = cameraFrame(player);
        try runDevKeys(world, player);
        updateInteractTarget(world, physics, player, frame);
        try interact(world, player);
        move(world, player, frame);
        resetOnReload(world, player);
        try useSkills(world, physics, player);
    }
}

fn cameraFrame(player: *const World.Entity) Frame {
    const planet_up = nz.vec.normalize(player.transform.position);
    const input = player.controller.input;
    const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(input.camera_rotation);
    const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
    const along_ground = math.projectOnPlane(camera_forward, planet_up);
    return .{
        .planet_up = planet_up,
        .camera_forward = camera_forward,
        .move_forward = if (nz.vec.length(along_ground) > 0.0001)
            nz.vec.normalize(along_ground)
        else
            nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 })),
    };
}

fn runDevKeys(world: *World, player: *World.Entity) !void {
    const keys = &player.controller.input.keys;
    if (take(keys, "dev_f1")) try spawnDevEnemy(world, player);
    if (take(keys, "dev_f2")) giveDevItems(world, player);
    if (take(keys, "dev_f3")) killAllEnemies(world);
    if (take(keys, "dev_f4")) dropRandomItem(world);
    if (take(keys, "dev_f5")) world.next_stage_requested = true;
    if (take(keys, "dev_f6")) _ = combat.addHealth(world, player, -player.health, null);
    if (take(keys, "dev_f7")) player.flags.invincible = !player.flags.invincible;
    if (take(keys, "dev_f8")) teleportToTeleporter(world, player);
    if (take(keys, "dev_f9")) world.start_round_requested = true;
}

fn take(keys: anytype, comptime key: []const u8) bool {
    defer @field(keys, key) = false;
    return @field(keys, key);
}

fn spawnDevEnemy(world: *World, player: *World.Entity) !void {
    _ = try world.spawn(.{ .kind = .{ .enemy = .grass_tank }, .transform = player.transform });
}

fn giveDevItems(world: *World, player: *World.Entity) void {
    _ = items.giveItem(world, player, .rocket, 1);
    _ = items.giveItem(world, player, .lightning, 1);
}

fn killAllEnemies(world: *World) void {
    world.toggle_spawning_requested = true;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .enemy) continue;
        _ = combat.addHealth(world, entity, -entity.max_health, null);
    }
}

fn aboveTeleporter(world: *World, height: f32) ?nz.Vec3(f32) {
    const teleporter = world.getPtr(world.teleporter_id) orelse return null;
    const position = teleporter.transform.position;
    return position + nz.vec.scale(shared.Planet.surfaceUp(position), height);
}

fn dropRandomItem(world: *World) void {
    const teleporter = world.getPtr(world.teleporter_id) orelse return;
    const random = world.prng.random();
    _ = world.spawn(.{
        .kind = .item_pickup,
        .item = random.enumValue(shared.Item.Kind),
        .transform = .{
            .position = aboveTeleporter(world, 10).?,
            .rotation = teleporter.transform.rotation,
        },
        .spawn_impulse = shared.Planet.surfaceLaunch(
            teleporter.transform.position,
            nz.vec.randomUnitVector(nz.Vec3(f32), random),
            World.item_launch_angle,
            World.item_throw_speed,
        ),
    }) catch {};
}

fn teleportToTeleporter(world: *World, player: *World.Entity) void {
    const destination = aboveTeleporter(world, 10) orelse return;
    world.act(.{ .id = player.id, .verb = .{ .teleport = destination } });
}

fn updateInteractTarget(
    world: *World,
    physics: *system.Physics,
    player: *World.Entity,
    frame: Frame,
) void {
    const input = &player.controller.input;
    const forward = frame.camera_forward;
    const player_depth = nz.vec.dot(player.transform.position - input.camera_position, forward);
    const ray_start = input.camera_position + nz.vec.scale(forward, player_depth);
    const hit = World.rayCast(physics, ray_start, nz.vec.scale(forward, 5));
    const hit_id: shared.entity.Id = if (hit) |found| found.id else .none;
    if (player.interacting == hit_id) return;
    player.interacting = hit_id;
    world.client_updates.appendAssumeCapacity(.{
        .event = .{ .interact = .{
            .interactor = player.id,
            .interacted = interactable(world, hit_id),
        } },
    });
}

fn interactable(world: *World, id: shared.entity.Id) shared.entity.Id {
    const entity = world.getPtr(id) orelse return .none;
    return switch (entity.kind) {
        .lootbox, .item_pickup => id,
        .teleporter => switch (entity.teleporter.state) {
            .active => .none,
            .completed => if (world.teleport_bosses.items.len > 0) .none else id,
            else => id,
        },
        else => .none,
    };
}

fn interact(world: *World, player: *World.Entity) !void {
    if (!player.controller.input.keys.interact) return;
    if (world.elapsed_time - player.last_interact < interact_cooldown) return;
    const target = world.getPtr(player.interacting) orelse return;
    player.last_interact = world.elapsed_time;
    switch (target.kind) {
        .lootbox => try openChest(world, player, target),
        .teleporter => try useTeleporter(world, player, target),
        .item_pickup => pickUp(world, player, target),
        else => {},
    }
}

fn openChest(world: *World, player: *World.Entity, chest: *World.Entity) !void {
    if (player.currency < chest.currency) return;
    world.queueDespawn(chest.id);
    const item_kind = shared.Item.rollChest(&shared.Item.small_chest_odds, world.prng.random());
    const chest_up = shared.Planet.surfaceUp(chest.transform.position);
    _ = try world.spawn(.{
        .kind = .item_pickup,
        .item = item_kind,
        .transform = .{
            .position = chest.transform.position + chest_up,
            .rotation = chest.transform.rotation,
        },
        .spawn_impulse = nz.vec.scale(chest_up, World.item_throw_speed),
    });
    player.currency -= chest.currency;
    world.client_updates.appendAssumeCapacity(.{
        .set_currency = .{ .id = player.id, .amount = player.currency },
    });
}

fn useTeleporter(world: *World, player: *World.Entity, teleporter_entity: *World.Entity) !void {
    const teleporter = &teleporter_entity.teleporter;
    if (teleporter.state == .idle) return activateTeleporter(world, player, teleporter_entity);
    if (world.place == .ship) return lobby.setReady(world, player, !player.ready);
    const charged = teleporter.charged == teleporter.max_charge;
    if (charged and world.teleport_bosses.items.len == 0) world.next_stage_requested = true;
}

fn activateTeleporter(world: *World, player: *World.Entity, teleporter: *World.Entity) !void {
    teleporter.teleporter.state = .active;
    world.client_updates.appendAssumeCapacity(.{ .event = .teleport_start });
    world.client_updates.appendAssumeCapacity(.{
        .event = .{ .interact = .{ .interactor = player.id, .interacted = .none } },
    });
    const random = world.prng.random();
    const near = teleporter.transform.position;
    const boss_surface = world.planet.surfacePointNear(near, 15, 25, random);
    const boss_position = boss_surface + nz.vec.scale(shared.Planet.surfaceUp(boss_surface), 3);
    _ = try world.spawn(.{
        .kind = .{ .enemy = .bloorp_lord },
        .transform = .{ .position = boss_position },
        .flags = .{ .is_teleporter_boss = true },
        .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
    });
}

fn pickUp(world: *World, player: *World.Entity, pickup: *World.Entity) void {
    _ = items.giveItem(world, player, pickup.item.?, 1) orelse return;
    world.queueDespawn(pickup.id);
}

fn move(world: *World, player: *World.Entity, frame: Frame) void {
    const input = &player.controller.input;
    const move_right = nz.vec.normalize(nz.vec.cross(frame.move_forward, frame.planet_up));
    player.camera.yaw_rotation = .lookAt(frame.move_forward, frame.planet_up);

    var direction: nz.Vec3(f32) = .{ 0, 0, 0 };
    if (input.keys.move_forward) direction += frame.move_forward;
    if (input.keys.move_backward) direction -= frame.move_forward;
    if (input.keys.move_right) direction += move_right;
    if (input.keys.move_left) direction -= move_right;

    const stun_slow: f32 = if (player.un_stun_at > world.elapsed_time) 0.3 else 1;
    if (input.keys.jump and player.mode == .walking) {
        world.act(.{ .id = player.id, .verb = .{ .jump = 20 } });
    }
    world.act(.{
        .id = player.id,
        .verb = .{ .walk = .{ .direction = direction, .speed = player.stat(.speed) * stun_slow } },
    });
    world.act(.{ .id = player.id, .verb = .{ .set_rotation = player.camera.yaw_rotation } });
    player.transform.rotation = player.camera.yaw_rotation;
}

fn resetOnReload(world: *World, player: *World.Entity) void {
    const controller = &player.controller;
    const pressed = controller.input.keys.reload and !controller.reload_held;
    controller.reload_held = controller.input.keys.reload;
    if (!pressed) return;
    controller.resync_requested = true;
    player.camera = .{};
    player.transform = .{};
    world.act(.{ .id = player.id, .verb = .{ .set_velocity = .{ 0, 0, 0 } } });
    world.act(.{ .id = player.id, .verb = .{ .teleport = .{ 0, 0, 0 } } });
    world.act(.{ .id = player.id, .verb = .{ .set_rotation = player.transform.rotation } });
}

fn useSkills(world: *World, physics: *system.Physics, player: *World.Entity) !void {
    const keys = player.controller.input.keys;
    const assigned = shared.entity.abilities(player.kind, player.survivor);
    const has_equipment = shared.Item.equippedEffect(player.inventory) != null;
    const held: []const struct { shared.entity.Action, bool } = &.{
        .{ .equipment, keys.use_equipment and has_equipment },
        .{ .primary, keys.attack },
        .{ .secondary, keys.secondary },
        .{ .utility, keys.utility },
        .{ .special, keys.special },
    };
    for (held) |entry| {
        const action, const pressed = entry;
        if (!pressed) continue;
        const skill = assigned.get(action) orelse continue;
        if (skills.useAction(world, player, null, action) != .fired) continue;
        try skills.executeSkill(world, physics, player, null, skill);
    }
}
