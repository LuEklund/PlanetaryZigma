const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const render_system = @import("render_system");
const render = @import("contract");
const Emitter = @import("render_system").Emitter;
const ModelTable = @import("render_system").ModelTable;
const Camera = @import("camera.zig");
const Ui = @import("ui");
const DrawList = @import("contract").DrawList;
const Viewer = @import("Viewer.zig");

pub fn frame(world: *World, viewer: *Viewer) !void {
    const list = &viewer.draw_list;
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

    // Chunks are meshes like any other: the sim publishes geometry, we hand it to the
    // renderer and keep the handle. Before the rows, so a chunk uploaded this frame draws.
    for (world.planet.removes.items) |removed| {
        if (removed.mesh_handle == 0) continue;
        viewer.render.api.freeMesh(viewer.render.handle, @enumFromInt(removed.mesh_handle));
    }
    for (world.planet.uploads.items) |chunk_upload| {
        const entry = world.planet.chunks.getPtr(chunk_upload.coord) orelse continue;
        const surfaces = [_]render.SurfaceUpload{.{
            .index_start = 0,
            .index_count = @intCast(chunk_upload.indices.len),
            .texture_slot = render.blank_texture,
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

    try viewer.animator.begin(.{
        .delta_time = world.delta_time,
        .elapsed_time = world.elapsed_time,
        .local_entity = if (followed) |player| player.id else .none,
        .camera_pitch = if (followed) |player| pitch: {
            const planet_up = shared.Planet.up(player.transform.position) orelse break :pitch 0;
            break :pitch std.math.asin(std.math.clamp(nz.vec.dot(camera_rotation.rotateVec(.{ 0, 0, -1 }), planet_up), -1, 1));
        } else camera.pitch,
        .camera_yaw_rotation = if (followed) |player| player.camera.yaw_rotation else camera.yaw_rotation,
    }, &.{}, &viewer.models);

    for (world.entities.values()) |*entity| {
        const model_spec = shared.entity.modelSpec(entity.kind) orelse continue;
        const model_handle = ModelTable.handleForKind(entity.kind) orelse continue;
        try viewer.animator.observe(.{
            .id = entity.id,
            .model = model_handle,
            .transform = entity.transform,
            .offset = model_spec.offset,
            .is_dying = false,
            .state = shared.entity.animationState(
                entity.replicated_velocity,
                @max(0, entity.un_stun_at - world.elapsed_time),
                false,
                null,
            ),
            .highlight = entity.kind == .teleporter,
            .spin_speed = if (entity.kind == .item) render_system.Animator.item_spin_speed else 0,
            .shrink_on_death = entity.kind == .lootbox,
            .effect = if (entity.kind == .item) .item_effect else null,
        }, &viewer.models);
    }
    viewer.animator.advance(&.{}, &viewer.models);
    viewer.animator.draw(list, &viewer.emitters, &viewer.models);

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
