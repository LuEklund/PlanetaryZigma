const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const graphics = @import("graphics");
const render = @import("contract");
const Emitter = @import("graphics").Emitter;
const Camera = @import("camera.zig");
const Ui = @import("ui");
const DrawList = @import("contract").DrawList;
const Viewer = @import("Viewer.zig");

pub fn frame(world: *World, viewer: *Viewer, gpa: std.mem.Allocator) !void {
    const list = &viewer.draw_list;
    const models = &viewer.assets.models;
    const camera = viewer.camera;
    const ui = &viewer.ui;
    // The wire carries the client's real camera; `Entity.camera` holds only the yaw
    // the sim needs for movement.
    const followed = if (camera.follow != .none) world.getPtr(camera.follow) else null;
    var camera_position: nz.Vec3(f32) = camera.position;
    var camera_rotation: nz.quat.Hamiltonian(f32) = camera.rotation();
    if (followed) |player| {
        const planet_up = shared.Planet.up(player.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
        const player_back = nz.vec.scale(player.transform.forward(), -1);
        camera_position = player.transform.position + nz.vec.scale(planet_up, 6) + nz.vec.scale(player_back, 10);
        const look_target = player.transform.position + nz.vec.scale(planet_up, 2);
        camera_rotation = .lookAt(nz.vec.normalize(look_target - camera_position), planet_up);
    }

    list.clear();
    list.camera = .{
        .position = camera_position,
        .rotation = camera_rotation,
        .fov_rad = 1.5,
    };
    list.time = world.elapsed_time;
    list.light_color = .{ 1, 1, 1, 1 };
    list.draw_sky = true;
    list.planet_radius = world.planet.radiusFloat();
    list.surface_width = viewer.window.size.width;
    list.surface_height = viewer.window.size.height;

    for (world.planet.removes.items) |removed| {
        if (removed.mesh_handle == 0) continue;
        viewer.render.api.freeMesh(viewer.render.handle, @enumFromInt(removed.mesh_handle));
    }
    for (world.planet.uploads.items) |chunk_upload| {
        const entry = world.planet.chunks.getPtr(chunk_upload.coord) orelse continue;
        const surfaces = [_]render.SurfaceUpload{.{
            .index_start = 0,
            .index_count = @intCast(chunk_upload.indices.len),
            .texture = .blank,
            .transparent = false,
        }};
        entry.mesh_handle = @intFromEnum(viewer.render.api.uploadMesh(viewer.render.handle, @enumFromInt(entry.mesh_handle), &.{
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

    const followed_aim: ?graphics.Animator.Aim = if (followed) |player| aim: {
        const planet_up = shared.Planet.up(player.transform.position) orelse break :aim null;
        const pitch = std.math.asin(std.math.clamp(nz.vec.dot(camera_rotation.rotateVec(.{ 0, 0, -1 }), planet_up), -1, 1));
        var yaw_offset = player.transform.rotation.conjugate().mul(player.camera.yaw_rotation);
        if (yaw_offset.w < 0) yaw_offset = .{ .w = -yaw_offset.w, .x = -yaw_offset.x, .y = -yaw_offset.y, .z = -yaw_offset.z };
        var yaw = std.math.clamp(2 * std.math.atan2(yaw_offset.y, yaw_offset.w), -1.2, 1.2);
        if (@abs(yaw) < 0.05) yaw = 0;
        break :aim .{ .pitch = std.math.clamp(-pitch, -1.0, 1.0), .yaw = yaw };
    } else null;

    for (world.entities.values()) |*entity| {
        const slot = try viewer.animations.getOrPut(gpa, entity.id);
        if (!slot.found_existing) slot.value_ptr.* = try viewer.animator.create(models.get(entity.kind), models);
        viewer.animator.setState(
            slot.value_ptr.*,
            entity.replicated_velocity,
            @max(0, entity.un_stun_at - world.elapsed_time),
            null,
        );
        const is_followed = if (followed) |player| player.id == entity.id else false;
        viewer.animator.setAim(slot.value_ptr.*, if (is_followed) followed_aim else null);
    }

    var animation_iterator = viewer.animations.iterator();
    while (animation_iterator.next()) |slot| {
        if (world.getPtr(slot.key_ptr.*) != null) continue;
        viewer.animator.destroy(slot.value_ptr.*);
        _ = viewer.animations.remove(slot.key_ptr.*);
        animation_iterator = viewer.animations.iterator();
    }

    try viewer.animator.advance(world.delta_time, models);

    for (world.entities.values()) |*entity| {
        const handle = viewer.animations.get(entity.id) orelse continue;
        const pose = viewer.animator.pose(handle) orelse continue;
        const model_spec: shared.entity.ModelSpec = shared.entity.modelSpec(entity.kind) orelse .{ .path = "", .clip_names = null };
        var transform = entity.transform;
        if (entity.kind == .item) {
            transform.rotation = transform.rotation
                .mul(nz.Quat(f32).angleAxis(graphics.Animator.item_spin_speed * world.elapsed_time, .{ 0, 1, 0 }))
                .normalize();
        }
        appendDraws(
            list,
            models,
            pose,
            transform.toMat4x4().mul(model_spec.offset.toMat4x4()),
            entity.transform.position,
            entity.kind == .teleporter,
        );
    }

    if (world.options.draw_flow_field) list.draw_lines.appendSliceAssumeCapacity(viewer.arrow_lines.items);
    if (world.options.draw_chunk_borders) list.draw_lines.appendSliceAssumeCapacity(viewer.border_lines.items);

    list.ui.quads.appendSliceAssumeCapacity(ui.quads.items);
    list.ui.screen_width = ui.screen_width;
    list.ui.screen_height = ui.screen_height;

    for (&viewer.emitters) |emitter| {
        if (!emitter.alive(world.elapsed_time)) continue;
        list.emitters.appendAssumeCapacity(.{
            .effect = emitter.effect,
            .origin = emitter.origin,
            .target = emitter.target,
            .spawn_time = emitter.spawn_time,
        });
    }

    viewer.render.api.update(viewer.render.handle, list);
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

const navmesh_arrow_color: [4]f32 = .{ 0.2, 0.9, 1.0, 1 };
const navmesh_arrow_budget: usize = 200000;

pub fn collectNavmeshArrows(world: *World, gpa: std.mem.Allocator, lines: *std.ArrayList(DrawList.Line)) !void {
    lines.clearRetainingCapacity();
    const navmesh = &world.navmesh;
    const active = navmesh.internal.active;
    var budget: usize = navmesh_arrow_budget;
    for (navmesh.internal.chunks.values()) |*nav_chunk| {
        const positions = nav_chunk.graph.cells.values();
        for (nav_chunk.next[active], 0..) |next_slot, node_index| {
            if (next_slot == 255) continue;
            const from = positions[node_index];
            const neighbor = nav_chunk.graph.neighbors[node_index * shared.Planet.Chunk.NavGraph.max_neighbor_count + next_slot];
            const to = switch (neighbor) {
                .none => continue,
                .boundary_edge => to: {
                    const cell = nav_chunk.graph.neighborCell(node_index, next_slot);
                    const chunk_coord: shared.Planet.Chunk.Coord = .{ .position = @divFloor(cell, @as(nz.Vec3(i32), @splat(shared.Planet.Chunk.dim))) };
                    const neighbor_chunk = navmesh.internal.chunks.getPtr(chunk_coord) orelse continue;
                    const neighbor_index = neighbor_chunk.graph.cells.getIndex(cell) orelse continue;
                    break :to neighbor_chunk.graph.cells.values()[neighbor_index];
                },
                _ => positions[@intFromEnum(neighbor)],
            };
            const lift = nz.vec.scale(nz.vec.normalize(from), 0.2);
            try lines.append(gpa, .{ .a = from + lift, .b = to + lift, .color = navmesh_arrow_color });
            budget -= 1;
            if (budget == 0) return;
        }
    }
}

const chunk_border_color: [4]f32 = .{ 1.0, 0.0, 0.1, 1 };

pub fn collectChunkBorders(world: *World, gpa: std.mem.Allocator, lines: *std.ArrayList(DrawList.Line)) !void {
    lines.clearRetainingCapacity();
    for (world.navmesh.internal.chunks.keys()) |coord| {
        const low: nz.Vec3(f32) = @floatFromInt(shared.Planet.Chunk.min(coord));
        const high: nz.Vec3(f32) = @floatFromInt(shared.Planet.Chunk.max(coord));
        const corners = [8]nz.Vec3(f32){
            .{ low[0], low[1], low[2] },
            .{ high[0], low[1], low[2] },
            .{ low[0], high[1], low[2] },
            .{ high[0], high[1], low[2] },
            .{ low[0], low[1], high[2] },
            .{ high[0], low[1], high[2] },
            .{ low[0], high[1], high[2] },
            .{ high[0], high[1], high[2] },
        };
        const edges = [12][2]usize{
            .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 },
            .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 },
            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
        };
        for (edges) |edge| try lines.append(gpa, .{ .a = corners[edge[0]], .b = corners[edge[1]], .color = chunk_border_color });
    }
}

/// Where the chunk sits, for the shadow-cascade test. Its geometry is already in world
/// space, so the draw itself needs no transform.
fn chunkCentre(coord: shared.Planet.Chunk.Coord) nz.Vec3(f32) {
    const dim: f32 = @floatFromInt(shared.Planet.Chunk.dim);
    const corner: nz.Vec3(f32) = @floatFromInt(coord.position);
    return corner * @as(nz.Vec3(f32), @splat(dim)) + @as(nz.Vec3(f32), @splat(dim / 2));
}
