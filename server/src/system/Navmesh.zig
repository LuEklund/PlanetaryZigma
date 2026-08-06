const Navmesh = @This();

const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");
const nz = shared.numz;

internal: Internal,
worker: ?std.Thread,
flood_seeds: [shared.max_players]Node,
flood_seed_count: usize,
player_seeds: [shared.max_players]PlayerSeed,
player_seed_count: usize,

const PlayerSeed = struct {
    id: shared.entity.Id,
    position: nz.Vec3(f32),
};

const Internal = struct {
    chunks: std.AutoArrayHashMapUnmanaged(shared.Planet.Chunk.Coord, NavChunk),
    active: u1,
    building: std.atomic.Value(bool),
};

const NavChunk = struct {
    graph: shared.Planet.Chunk.NavGraph,
    cost: [2][]f32,
    next: [2][]u8,

    fn init(gpa: std.mem.Allocator, graph: shared.Planet.Chunk.NavGraph) !NavChunk {
        const node_count = graph.cells.count();
        var cost: [2][]f32 = undefined;
        var next: [2][]u8 = undefined;
        inline for (0..2) |buffer| {
            cost[buffer] = try gpa.alloc(f32, node_count);
            errdefer gpa.free(cost[buffer]);
            @memset(cost[buffer][0..node_count], std.math.inf(f32));
            next[buffer] = try gpa.alloc(u8, node_count);
            errdefer gpa.free(next[buffer]);
            @memset(next[buffer][0..node_count], no_next);
        }
        return .{ .graph = graph, .cost = cost, .next = next };
    }

    fn deinit(self: *NavChunk, gpa: std.mem.Allocator) void {
        self.graph.deinit(gpa);
        for (self.cost) |buffer| gpa.free(buffer);
        for (self.next) |buffer| gpa.free(buffer);
    }
};

const no_next: u8 = 255;

const rebuild_distance: f32 = 8;

pub const empty: Navmesh = .{
    .internal = .{
        .chunks = .empty,
        .active = 0,
        .building = .init(false),
    },
    .worker = null,
    .flood_seeds = undefined,
    .flood_seed_count = 0,
    .player_seeds = undefined,
    .player_seed_count = 0,
};

pub fn deinit(self: *Navmesh, gpa: std.mem.Allocator) void {
    if (self.worker) |thread| thread.join();
    for (self.internal.chunks.values()) |*nav| nav.deinit(gpa);
    self.internal.chunks.deinit(gpa);
}

pub fn update(self: *Navmesh, world: *World) !void {
    if (self.worker) |thread| {
        if (self.internal.building.load(.acquire)) return;
        thread.join();
        self.worker = null;
        self.internal.active ^= 1;
    }
    if (!self.needsRebuild(world)) return;
    const gpa = world.gpa;
    const planet = &world.planet;
    var chunk_index: usize = self.internal.chunks.count();
    while (chunk_index > 0) {
        chunk_index -= 1;
        if (planet.chunks.contains(self.internal.chunks.keys()[chunk_index])) continue;
        self.internal.chunks.values()[chunk_index].deinit(gpa);
        self.internal.chunks.swapRemoveAt(chunk_index);
    }
    for (planet.chunks.keys(), planet.chunks.values()) |coord, *chunk_entry| {
        if (self.internal.chunks.contains(coord)) continue;
        try self.internal.chunks.put(gpa, coord, try NavChunk.init(gpa, try chunk_entry.nav.clone(gpa)));
    }

    self.player_seed_count = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        self.player_seeds[self.player_seed_count] = .{ .id = player.id, .position = player.transform.position };
        self.player_seed_count += 1;
    }

    self.flood_seed_count = self.collectSeeds(planet, &self.flood_seeds);
    if (self.flood_seed_count == 0) return;
    self.internal.building.store(true, .release);
    self.worker = std.Thread.spawn(.{}, floodWorker, .{ self, gpa }) catch |err| {
        self.internal.building.store(false, .release);
        std.log.err("navmesh: flood worker spawn: {s}", .{@errorName(err)});
        return;
    };
}

fn floodWorker(self: *Navmesh, gpa: std.mem.Allocator) void {
    const generating: u1 = self.internal.active ^ 1;

    for (self.internal.chunks.values()) |*nav_chunk| {
        @memset(nav_chunk.cost[generating][0..nav_chunk.cost[generating].len], std.math.inf(f32));
        @memset(nav_chunk.next[generating][0..nav_chunk.next[generating].len], no_next);
    }

    var queue: std.Deque(Node) = .empty;
    defer queue.deinit(gpa);

    for (self.flood_seeds[0..self.flood_seed_count]) |seed| {
        const nav_chunk = self.internal.chunks.getPtr(seed.chunk_coord) orelse continue;
        nav_chunk.cost[generating][seed.chunk_cell_index] = 0;
        queue.pushBack(gpa, seed) catch return;
    }

    while (queue.popFront()) |current| {
        const current_chunk = self.internal.chunks.getPtr(current.chunk_coord).?;
        const current_cost = current_chunk.cost[generating][current.chunk_cell_index];
        const slot_base = @as(usize, current.chunk_cell_index) * shared.Planet.Chunk.NavGraph.max_neighbor_count;

        for (0..shared.Planet.Chunk.NavGraph.max_neighbor_count) |slot| {
            const neighbor = current_chunk.graph.neighbors[slot_base + slot];
            if (neighbor == .none) continue;

            var neighbor_chunk_coord = current.chunk_coord;
            var neighbor_chunk = current_chunk;
            var neighbor_index: u16 = @intFromEnum(neighbor);
            if (neighbor == .boundary_edge) {
                const cell = current_chunk.graph.cells.keys()[current.chunk_cell_index] + shared.Planet.Chunk.NavGraph.neighbor_offsets[slot];
                neighbor_chunk_coord = .{ .position = @divFloor(cell, @as(nz.Vec3(i32), @splat(shared.Planet.Chunk.dim))) };
                neighbor_chunk = self.internal.chunks.getPtr(neighbor_chunk_coord) orelse continue;
                neighbor_index = @intCast(neighbor_chunk.graph.cells.getIndex(cell) orelse continue);
            }

            const new_cost = current_cost + current_chunk.graph.weights[slot_base + slot];
            if (new_cost >= neighbor_chunk.cost[generating][neighbor_index]) continue;
            neighbor_chunk.cost[generating][neighbor_index] = new_cost;
            neighbor_chunk.next[generating][neighbor_index] = @intCast(slot ^ 1);
            queue.pushBack(gpa, .{ .chunk_coord = neighbor_chunk_coord, .chunk_cell_index = neighbor_index }) catch return;
        }
    }
    self.internal.building.store(false, .release);
}

pub const Node = struct {
    chunk_coord: shared.Planet.Chunk.Coord,
    chunk_cell_index: u16,
};

fn lookupNode(self: *const Navmesh, planet: *const shared.Planet, position: nz.Vec3(f32)) ?Node {
    const surface_point = planet.surfacePoint(position);
    const cell: nz.Vec3(i32) = @intFromFloat(@floor(surface_point));
    const down_step: nz.Vec3(i32) = @intFromFloat(@round(-nz.vec.normalize(position)));

    const candidates = [4]nz.Vec3(i32){ cell, cell + down_step, cell - down_step, cell + down_step + down_step };
    for (candidates) |candidate| {
        const chunk_coord: shared.Planet.Chunk.Coord = .{ .position = @divFloor(candidate, @as(nz.Vec3(i32), @splat(shared.Planet.Chunk.dim))) };
        const nav_chunk = self.internal.chunks.getPtr(chunk_coord) orelse continue;
        const node_index = nav_chunk.graph.cells.getIndex(candidate) orelse continue;
        return .{ .chunk_coord = chunk_coord, .chunk_cell_index = @intCast(node_index) };
    }
    return null;
}

fn collectSeeds(self: *const Navmesh, planet: *const shared.Planet, out: *[shared.max_players]Node) usize {
    var count: usize = 0;
    for (self.player_seeds[0..self.player_seed_count]) |seed| {
        const node = self.lookupNode(planet, seed.position) orelse {
            std.log.err("navmesh: no start node for player {d} at {d:.1} {d:.1} {d:.1}", .{ @intFromEnum(seed.id), seed.position[0], seed.position[1], seed.position[2] });
            continue;
        };
        out[count] = node;
        count += 1;
    }
    return count;
}

fn needsRebuild(self: *Navmesh, world: *World) bool {
    if (self.internal.chunks.count() != world.planet.chunks.count()) return true;
    var player_index: usize = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        const delta = player.transform.position - self.player_seeds[player_index].position;
        if (nz.vec.dot(delta, delta) > rebuild_distance * rebuild_distance) return true;
        player_index += 1;
    }
    return player_index != self.player_seed_count;
}
