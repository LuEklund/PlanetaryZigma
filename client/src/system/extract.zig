const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const System = @import("../System.zig");
const DrawList = @import("renderer_contract").DrawList;
const graphics = @import("graphics");
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
    list.surface_width = system.window.size.width;
    list.surface_height = system.window.size.height;

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
    if (world.getPtr(world.teleporter_id)) |teleporter| {
        if (teleporter.teleporter.state == .active) {
            const sphere: nz.Transform3D(f32) = .{
                .position = teleporter.transform.position,
                .scale = @splat(shared.teleporter.charge_distance),
            };
            appendDraws(
                list,
                models,
                .{ .model = system.teleport_sphere_model, .skeleton = null },
                sphere.toMat4x4(),
                teleporter.transform.position,
                false,
            );
        }
    }

    for (world.effects.items) |request| Emitter.spawn(emitters, request, world.elapsed_time);
    world.effects.clearRetainingCapacity();

    const player_interact: shared.entity.Id = if (world.getPtr(world.player_id)) |player| player.interacting else .none;
    for (world.entities.values()) |*entity| {
        if (entity.kind == .item_pickup) {
            const effect_offset = nz.vec.scale(nz.vec.normalize(entity.transform.position), 0.5);
            Emitter.keepAlive(emitters, .item_effect, @intFromEnum(entity.id), entity.transform.position - effect_offset, world.elapsed_time);
        }
        const pose = animator.pose(entity.animation) orelse continue;
        const model_spec: shared.entity.ModelSpec = entity.kind.modelSpec() orelse .{ .path = "", .loop_clips = null };
        var transform = entity.transform;
        if (entity.kind == .item_pickup) {
            const spawn_duration = shared.entity.Kind.spec(.item_pickup).spawn_duration;
            const alive_time = world.elapsed_time - entity.spawned_at;
            if (spawn_duration > 0) {
                transform.scale = @splat(0.1 + 0.9 * easeOutBack(std.math.clamp(alive_time / spawn_duration, 0, 1)));
            }
            transform.rotation = transform.rotation
                .mul(nz.Quat(f32).angleAxis(graphics.Animator.item_spin_speed * alive_time, .{ 0, 1, 0 }))
                .normalize();
        }
        appendDraws(
            list,
            models,
            pose,
            transform.toMat4x4().mul(model_spec.offset.toMat4x4()),
            entity.transform.position,
            player_interact == entity.id,
        );
    }
    for (world.dying.items) |corpse| {
        const pose = animator.pose(corpse.animation) orelse continue;
        const corpse_spec: shared.entity.ModelSpec = corpse.kind.modelSpec() orelse .{ .path = "", .loop_clips = null };
        var transform = corpse.transform;
        if (corpse.kind == .lootbox) {
            const death_duration = models.rig(models.get(corpse.kind)).death_duration;
            if (death_duration > 0) {
                transform.scale = @splat(1.0 - std.math.clamp(corpse.elapsed / death_duration, 0, 1));
            }
        }
        appendDraws(
            list,
            models,
            pose,
            transform.toMat4x4().mul(corpse_spec.offset.toMat4x4()),
            corpse.transform.position,
            false,
        );
    }

    if (world.controller.debug_draw_colliders) {
        for (world.entities.values()) |*entity| {
            const collider_shape = (entity.kind.collider() orelse continue).shape;
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

fn easeOutBack(x: f32) f32 {
    const c1: f32 = 1.70158;
    const c3: f32 = c1 + 1.0;
    const xm1 = x - 1.0;
    return 1.0 + c3 * xm1 * xm1 * xm1 + c1 * xm1 * xm1;
}

fn appendDraws(list: *DrawList, models: *const graphics.Assets.Models, pose: graphics.Animator.Pose, top_matrix: nz.Mat4x4(f32), position: nz.Vec3(f32), highlight: bool) void {
    if (pose.skeleton) |skeleton| {
        var skin_offsets: [graphics.Animator.max_skins]u32 = undefined;
        const palette_base: u32 = @intCast(list.joint_matrices.items.len);
        list.joint_matrices.appendSliceAssumeCapacity(skeleton.joints);
        for (0..skeleton.skin_starts.len - 1) |skin_index| {
            skin_offsets[skin_index] = palette_base + skeleton.skin_starts[skin_index];
        }
        const mesh_handles = models.modelPtr(pose.model).mesh_handles;
        for (skeleton.nodes) |node| {
            const mesh_id = node.mesh_id orelse continue;
            if (mesh_id >= mesh_handles.len) continue;
            list.draw_meshes.appendAssumeCapacity(.{
                .mesh = @enumFromInt(mesh_handles[mesh_id]),
                .model_matrix = if (node.skin_id != null) top_matrix else top_matrix.mul(node.model_matrix),
                .position = position,
                .palette_offset = if (node.skin_id) |skin_index| skin_offsets[skin_index] else null,
                .skinned = true,
                .highlight = highlight,
            });
        }
        return;
    }

    const model = models.modelPtr(pose.model);
    if (model.isSkinned()) return;
    if (model.isEmpty()) {
        list.draw_meshes.appendAssumeCapacity(.{
            .mesh = .none,
            .model_matrix = top_matrix,
            .position = position,
            .palette_offset = null,
            .skinned = false,
            .highlight = highlight,
        });
        return;
    }
    for (model.surfaces.items) |surface| {
        if (surface.mesh_id >= model.mesh_handles.len) continue;
        list.draw_meshes.appendAssumeCapacity(.{
            .mesh = @enumFromInt(model.mesh_handles[surface.mesh_id]),
            .model_matrix = top_matrix.mul(surface.model_matrix),
            .position = position,
            .palette_offset = null,
            .skinned = false,
            .highlight = highlight,
        });
    }
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

fn chunkCentre(coord: shared.Planet.Chunk.Coord) nz.Vec3(f32) {
    const dim: f32 = @floatFromInt(shared.Planet.Chunk.dim);
    const corner: nz.Vec3(f32) = @floatFromInt(coord.position);
    return corner * @as(nz.Vec3(f32), @splat(dim)) + @as(nz.Vec3(f32), @splat(dim / 2));
}
