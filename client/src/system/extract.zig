const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Ui = @import("ui");
const System = @import("../System.zig");
const DrawList = @import("contract").DrawList;
const graphics = @import("graphics");
const render = @import("contract");
const Emitter = @import("graphics").Emitter;

const collider_color: [4]f32 = .{ 0, 1, 0, 1 };
const circle_segments = 16;

pub fn frame(system: *System, world: *World, draw_sky: bool) !void {
    const animator = &system.animator;
    const models = &system.assets.models;
    const emitters = &system.emitters;
    const ui = &system.hud.ui;
    const list = &system.draw_list;

    list.clear();
    list.camera = .{
        .position = world.camera.transform.position,
        .rotation = world.camera.transform.rotation,
        .fov_rad = world.options.fov_rad,
    };
    list.time = world.elapsed_time;
    list.light_color = if (world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{ 1, 0.5, 0.5, 1 };
    list.draw_sky = draw_sky;
    list.planet_radius = world.planet.radiusFloat();
    list.surface_width = @intFromFloat(ui.screen_width);
    list.surface_height = @intFromFloat(ui.screen_height);

    for (world.planet.removes.items) |removed| {
        if (removed.mesh_handle == 0) continue;
        system.render.api.freeMesh(system.render.handle, @enumFromInt(removed.mesh_handle));
    }
    for (world.planet.uploads.items) |chunk_upload| {
        const entry = world.planet.chunks.getPtr(chunk_upload.coord) orelse continue;
        const surfaces = [_]render.SurfaceUpload{.{
            .index_start = 0,
            .index_count = @intCast(chunk_upload.indices.len),
            .texture = .blank,
        }};
        entry.mesh_handle = @intFromEnum(system.render.api.uploadMesh(system.render.handle, @enumFromInt(entry.mesh_handle), &.{
            .name = "chunk",
            .vertices = std.mem.sliceAsBytes(chunk_upload.vertices),
            .skinned = false,
            .indices = chunk_upload.indices,
            .surfaces = &surfaces,
        }));
    }
    for (world.planet.chunks.keys(), world.planet.chunks.values()) |coord, entry| {
        if (entry.mesh_handle == 0) continue;
        list.draw_meshes.appendAssumeCapacity(.{
            .mesh = @enumFromInt(entry.mesh_handle),
            .model_matrix = .identity,
            .position = chunkCentre(coord),
            .palette_offset = null,
            .skinned = false,
            .highlight = false,
        });
    }

    try animator.begin(.{
        .delta_time = world.delta_time,
        .elapsed_time = world.elapsed_time,
        .local_entity = world.player_id,
        .camera_pitch = world.camera.pitch,
        .camera_yaw_rotation = world.camera.yaw_rotation,
    }, world.deaths.items, models);
    world.deaths.clearRetainingCapacity();

    for (world.effects.items) |request| Emitter.spawn(emitters, request, world.elapsed_time);
    world.effects.clearRetainingCapacity();

    const player_interact: shared.entity.Id = if (world.getPtr(world.player_id)) |player| player.interacting else .none;
    for (world.entities.values()) |*entity| {
        const model_spec: shared.entity.ModelSpec = shared.entity.modelSpec(entity.kind) orelse .{ .path = "", .clip_names = null };
        const model_handle = models.get(entity.kind);
        try animator.observe(.{
            .id = entity.id,
            .model = model_handle,
            .transform = entity.transform,
            .offset = model_spec.offset,
            .is_dying = entity.flags.is_dying,
            .state = shared.entity.animationState(
                if (entity.motion.update) |update_motion| update_motion.velocity else @splat(0),
                entity.stun_time,
                entity.flags.is_dying,
                entity.override_animation_state,
            ),
            .highlight = player_interact == entity.id,
            .spin_speed = if (entity.kind == .item) graphics.Animator.item_spin_speed else 0,
            .shrink_on_death = entity.kind == .lootbox,
            .effect = if (entity.kind == .item) .item_effect else null,
        }, models);
    }

    animator.advance(world.trigger_events.items, models);
    world.trigger_events.clearRetainingCapacity();
    animator.draw(list, emitters, models);

    if (world.controller.debug_draw_colliders) {
        for (world.entities.values()) |*entity| {
            const collider_shape = (shared.entity.collider(entity.kind) orelse continue).shape;
            var collider_transform = entity.transform;
            collider_transform.scale = @splat(1);
            switch (collider_shape) {
                .capsule => |capsule| appendCapsuleLines(list, collider_transform, capsule.half_height, capsule.radius),
                .box => |box| appendBoxLines(list, collider_transform, box),
            }
        }
    }

    list.ui.quads.appendSliceAssumeCapacity(ui.quads.items);
    list.ui.screen_width = ui.screen_width;
    list.ui.screen_height = ui.screen_height;

    for (emitters) |emitter| {
        if (!emitter.alive(world.elapsed_time)) continue;
        list.emitters.appendAssumeCapacity(.{
            .effect = emitter.effect,
            .origin = emitter.origin,
            .target = emitter.target,
            .spawn_time = emitter.spawn_time,
        });
    }

    system.render.api.update(system.render.handle, list);
}

fn appendLine(list: *DrawList, transform: nz.Transform3D(f32), from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    list.draw_lines.appendAssumeCapacity(.{
        .a = transform.position + transform.rotation.rotateVec(from),
        .b = transform.position + transform.rotation.rotateVec(to),
        .color = collider_color,
    });
}

fn appendCapsuleLines(list: *DrawList, transform: nz.Transform3D(f32), half_height: f32, radius: f32) void {
    for (0..circle_segments) |segment| {
        const angle_start = std.math.tau * @as(f32, @floatFromInt(segment)) / circle_segments;
        const angle_end = std.math.tau * @as(f32, @floatFromInt(segment + 1)) / circle_segments;
        for ([2]f32{ -half_height, half_height }) |ring_y| {
            appendLine(
                list,
                transform,
                .{ radius * @cos(angle_start), ring_y, radius * @sin(angle_start) },
                .{ radius * @cos(angle_end), ring_y, radius * @sin(angle_end) },
            );
        }
    }
    for (0..4) |quarter| {
        const angle = std.math.tau * @as(f32, @floatFromInt(quarter)) / 4;
        appendLine(
            list,
            transform,
            .{ radius * @cos(angle), -half_height, radius * @sin(angle) },
            .{ radius * @cos(angle), half_height, radius * @sin(angle) },
        );
    }
    const arc_segments = circle_segments / 2;
    for (0..arc_segments) |segment| {
        const angle_start = std.math.pi * @as(f32, @floatFromInt(segment)) / arc_segments;
        const angle_end = std.math.pi * @as(f32, @floatFromInt(segment + 1)) / arc_segments;
        for ([2]f32{ 1, -1 }) |cap_direction| {
            const cap_y = cap_direction * half_height;
            appendLine(
                list,
                transform,
                .{ radius * @cos(angle_start), cap_y + cap_direction * radius * @sin(angle_start), 0 },
                .{ radius * @cos(angle_end), cap_y + cap_direction * radius * @sin(angle_end), 0 },
            );
            appendLine(
                list,
                transform,
                .{ 0, cap_y + cap_direction * radius * @sin(angle_start), radius * @cos(angle_start) },
                .{ 0, cap_y + cap_direction * radius * @sin(angle_end), radius * @cos(angle_end) },
            );
        }
    }
}

fn appendBoxLines(list: *DrawList, transform: nz.Transform3D(f32), box: shared.entity.ColliderShape.HalfBoxExtent) void {
    const bottom_corners = [4]nz.Vec3(f32){
        .{ -box.x, -box.y, -box.z },
        .{ box.x, -box.y, -box.z },
        .{ box.x, -box.y, box.z },
        .{ -box.x, -box.y, box.z },
    };
    var top_corners = bottom_corners;
    for (&top_corners) |*corner| corner[1] = box.y;

    for (0..4) |corner_index| {
        const next_corner_index = (corner_index + 1) % 4;
        appendLine(list, transform, bottom_corners[corner_index], bottom_corners[next_corner_index]);
        appendLine(list, transform, top_corners[corner_index], top_corners[next_corner_index]);
        appendLine(list, transform, bottom_corners[corner_index], top_corners[corner_index]);
    }
}

/// Where the chunk sits, for the shadow-cascade test. Its geometry is already in world
/// space, so the draw itself needs no transform.
fn chunkCentre(coord: shared.Planet.Chunk.Coord) nz.Vec3(f32) {
    const dim: f32 = @floatFromInt(shared.Planet.Chunk.dim);
    const corner: nz.Vec3(f32) = @floatFromInt(coord.position);
    return corner * @as(nz.Vec3(f32), @splat(dim)) + @as(nz.Vec3(f32), @splat(dim / 2));
}
