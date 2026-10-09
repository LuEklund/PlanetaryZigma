const shared = @import("shared");
const system = @import("../System.zig");
const World = system.World;
const tracy = @import("ztracy");
const combat = @import("combat.zig");
const items = @import("items.zig");
const skills = @import("skills.zig");
const nz = shared.numz;

const interact_cooldown: f32 = 0.3;

pub fn update(world: *World, physics: *system.Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        const camera = &player.camera;
        const transform = &player.transform;
        const controller = &player.controller;
        const input = &controller.input;

        const planet_up = nz.vec.normalize(transform.position);
        const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(input.camera_rotation);

        const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
        const fwd_proj = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
        const move_fwd = if (nz.vec.length(fwd_proj) > 0.0001)
            nz.vec.normalize(fwd_proj)
        else
            nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
        const stun_slow: f32 = if (player.un_stun_at > world.elapsed_time) 0.3 else 1;
        const speed = player.stat(.speed) * stun_slow;

        if (input.keys.dev_f1) {
            input.keys.dev_f1 = false;
            _ = try world.spawn(.{ .kind = .{ .enemy = .grass_tank }, .transform = player.transform });
        }
        if (input.keys.dev_f2) {
            input.keys.dev_f2 = false;
            _ = items.giveItem(world, player, .rocket, 1);
            _ = items.giveItem(world, player, .lightning, 1);
        }
        if (input.keys.dev_f3) {
            input.keys.dev_f3 = false;
            world.toggle_spawning_requested = true;
            for (world.entities.values()) |*entity| {
                if (entity.kind == .enemy) _ = combat.addHealth(world, entity, -entity.max_health, null);
            }
        }
        if (input.keys.dev_f4) {
            input.keys.dev_f4 = false;
            if (world.getPtr(world.teleporter_id)) |teleporter| {
                const teleporter_up = shared.Planet.up(teleporter.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                const random = world.prng.random();
                _ = world.spawn(.{
                    .kind = .item_pickup,
                    .item = random.enumValue(shared.Item.Kind),
                    .transform = .{
                        .position = teleporter.transform.position + nz.vec.scale(teleporter_up, 10),
                        .rotation = teleporter.transform.rotation,
                    },
                    .spawn_impulse = shared.Planet.surfaceLaunch(
                        teleporter.transform.position,
                        nz.vec.randomUnitVector(nz.Vec3(f32), world.prng.random()),
                        World.item_launch_angle,
                        World.item_throw_speed,
                    ),
                }) catch {};
            }
        }
        if (input.keys.dev_f5) {
            input.keys.dev_f5 = false;
            world.next_stage_requested = true;
        }
        if (input.keys.dev_f6) {
            input.keys.dev_f6 = false;
            _ = combat.addHealth(world, player, -player.health, null);
        }
        if (input.keys.dev_f7) {
            input.keys.dev_f7 = false;
            player.flags.invincible = !player.flags.invincible;
        }
        if (input.keys.dev_f8) {
            input.keys.dev_f8 = false;
            if (world.getPtr(world.teleporter_id)) |teleporter| {
                const teleporter_up = shared.Planet.up(teleporter.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                world.act(.{ .id = player_id, .verb = .{ .teleport = teleporter.transform.position + nz.vec.scale(teleporter_up, 10) } });
            }
        }
        if (input.keys.dev_f9) {
            input.keys.dev_f9 = false;
            world.start_round_requested = true;
        }

        const player_depth = nz.vec.dot(player.transform.position - input.camera_position, camera_forward);
        const ray_position_start = input.camera_position + nz.vec.scale(camera_forward, player_depth);
        const ray_position_end = nz.vec.scale(camera_forward, 5);
        const hit_id: shared.entity.Id = if (World.rayCast(physics, ray_position_start, ray_position_end)) |hit| hit.id else .none;
        if (player.interacting != hit_id) {
            player.interacting = hit_id;
            const interact_id: shared.entity.Id = if (world.getPtr(hit_id)) |hit_entity|
                switch (hit_entity.kind) {
                    .lootbox, .item_pickup => hit_id,
                    .teleporter => switch (hit_entity.teleporter.state) {
                        .active => .none,
                        .completed => if (world.teleport_bosses.items.len > 0) .none else hit_id,
                        else => hit_id,
                    },
                    else => .none,
                }
            else
                .none;
            world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = interact_id } } });
        }

        if (player.controller.input.keys.interact and world.elapsed_time - player.last_interact >= interact_cooldown) if (world.getPtr(player.interacting)) |entity| {
            player.last_interact = world.elapsed_time;
            switch (entity.kind) {
                .lootbox => if (player.currency >= entity.currency) {
                    world.queueDespawn(entity.id);

                    const random = world.prng.random();
                    const item_kind = shared.Item.rollChest(&shared.Item.small_chest_odds, random);
                    const chest_up = shared.Planet.up(entity.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                    _ = try world.spawn(.{
                        .kind = .item_pickup,
                        .item = item_kind,
                        .transform = .{
                            .position = entity.transform.position + nz.vec.scale(chest_up, 1),
                            .rotation = entity.transform.rotation,
                        },
                        .spawn_impulse = nz.vec.scale(chest_up, World.item_throw_speed),
                    });
                    player.currency -= entity.currency;
                    world.client_updates.appendAssumeCapacity(.{ .set_currency = .{ .id = player_id, .amount = player.currency } });
                },
                .teleporter => {
                    const teleporter = &entity.teleporter;
                    if (teleporter.state == .idle) {
                        teleporter.state = .active;
                        world.client_updates.appendAssumeCapacity(.{ .event = .teleport_start });
                        world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = .none } } });
                        const boss_surface = world.planet.surfacePointNear(entity.transform.position, 15, 25, world.prng.random());
                        _ = try world.spawn(.{
                            .kind = .{ .enemy = .bloorp_lord },
                            .transform = .{ .position = boss_surface + nz.vec.scale(nz.vec.normalize(boss_surface), 3) },
                            .flags = .{ .is_teleporter_boss = true },
                            .last_used = .initDefault(0, .{ .primary = world.elapsed_time }),
                        });
                    } else {
                        if (teleporter.charged == teleporter.max_charge and world.teleport_bosses.items.len == 0) {
                            world.next_stage_requested = true;
                        }
                    }
                },
                .item_pickup => {
                    _ = items.giveItem(world, player, entity.item.?, 1) orelse continue;
                    world.queueDespawn(entity.id);
                },
                else => {},
            }
        };

        const move_right = nz.vec.normalize(nz.vec.cross(move_fwd, planet_up));
        camera.yaw_rotation = .lookAt(move_fwd, planet_up);

        var dir: nz.Vec3(f32) = .{ 0, 0, 0 };
        if (input.keys.move_forward) dir += move_fwd;
        if (input.keys.move_backward) dir -= move_fwd;
        if (input.keys.move_right) dir += move_right;
        if (input.keys.move_left) dir -= move_right;

        if (input.keys.jump and player.mode == .walking) world.act(.{ .id = player_id, .verb = .{ .jump = 20 } });

        world.act(.{ .id = player_id, .verb = .{ .walk = .{ .direction = dir, .speed = speed } } });

        world.act(.{ .id = player_id, .verb = .{ .set_rotation = camera.yaw_rotation } });
        transform.rotation = camera.yaw_rotation;

        const reload_pressed = input.keys.reload and !controller.reload_held;
        controller.reload_held = input.keys.reload;
        if (reload_pressed) {
            controller.resync_requested = true;
            camera.* = .{};
            transform.* = .{};
            world.act(.{ .id = player_id, .verb = .{ .set_velocity = .{ 0, 0, 0 } } });
            world.act(.{ .id = player_id, .verb = .{ .teleport = .{ 0, 0, 0 } } });
            world.act(.{ .id = player_id, .verb = .{ .set_rotation = transform.rotation } });
        }
        const player_skills = shared.entity.Kind.spec(.player).skills;
        if (input.keys.use_equipment and shared.Item.equippedEffect(player.inventory) != null and skills.useAction(world, player, null, .equipment) == .fired) {
            try skills.executeSkill(world, physics, player, null, player_skills.get(.equipment).?.skill);
        }
        if (input.keys.attack and skills.useAction(world, player, null, .primary) == .fired) {
            try skills.executeSkill(world, physics, player, null, player_skills.get(.primary).?.skill);
        }
        if (input.keys.secondary and skills.useAction(world, player, null, .secondary) == .fired) {
            try skills.executeSkill(world, physics, player, null, player_skills.get(.secondary).?.skill);
        }
        if (input.keys.utility and skills.useAction(world, player, null, .utility) == .fired) {
            try skills.executeSkill(world, physics, player, null, player_skills.get(.utility).?.skill);
        }
    }
}
