const Navmesh = @This();

const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");
const nz = shared.numz;

internal: Internal,
worker: ?std.Thread,
player_seeds: [shared.max_players]PlayerSeed,
player_seed_count: usize,

const PlayerSeed = struct {
    id: shared.entity.Id,
    position: nz.Vec3(f32),
    cell: nz.Vec3(i32),
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

pub const nav_reach: i32 = 2;

pub const rebuild_distance: f32 = 8;

pub const empty: Navmesh = .{
    .internal = .{
        .chunks = .empty,
        .active = 0,
        .building = .init(false),
    },
    .worker = null,
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
        self.player_seeds[self.player_seed_count] = .{
            .id = player.id,
            .position = player.transform.position,
            .cell = @intFromFloat(@floor(planet.surfacePoint(player.transform.position))),
        };
        self.player_seed_count += 1;
    }

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

    var queue: std.Deque(NodeRef) = .empty;
    defer queue.deinit(gpa);

    var flood_seeds: [shared.max_players]NodeRef = undefined;
    const flood_seed_count = self.collectSeeds(&flood_seeds);
    for (flood_seeds[0..flood_seed_count]) |seed| {
        seed.chunk.cost[generating][seed.index] = 0;
        queue.pushBack(gpa, seed) catch return;
    }

    while (queue.popFront()) |current| {
        const current_cost = current.chunk.cost[generating][current.index];
        const slot_base = @as(usize, current.index) * shared.Planet.Chunk.NavGraph.max_neighbor_count;

        for (0..shared.Planet.Chunk.NavGraph.max_neighbor_count) |slot| {
            const neighbor = self.neighborNode(current, slot) orelse continue;
            const new_cost = current_cost + current.chunk.graph.weights[slot_base + slot];
            if (new_cost >= neighbor.chunk.cost[generating][neighbor.index]) continue;
            neighbor.chunk.cost[generating][neighbor.index] = new_cost;
            neighbor.chunk.next[generating][neighbor.index] = @intCast(slot ^ 1);
            queue.pushBack(gpa, neighbor) catch return;
        }
    }
    self.internal.building.store(false, .release);
}

const NodeRef = struct {
    chunk: *NavChunk,
    coord: shared.Planet.Chunk.Coord,
    index: u16,
};

fn nodeAt(self: *const Navmesh, cell: nz.Vec3(i32)) ?NodeRef {
    const coord: shared.Planet.Chunk.Coord = .{ .position = @divFloor(cell, @as(nz.Vec3(i32), @splat(shared.Planet.Chunk.dim))) };
    const chunk = self.internal.chunks.getPtr(coord) orelse return null;
    const index = chunk.graph.cells.getIndex(cell) orelse return null;
    return .{ .chunk = chunk, .coord = coord, .index = @intCast(index) };
}

fn neighborNode(self: *const Navmesh, node: NodeRef, slot: usize) ?NodeRef {
    const neighbor = node.chunk.graph.neighbors[@as(usize, node.index) * shared.Planet.Chunk.NavGraph.max_neighbor_count + slot];
    return switch (neighbor) {
        .none => null,
        .boundary_edge => self.nodeAt(node.chunk.graph.neighborCell(node.index, slot)),
        _ => .{ .chunk = node.chunk, .coord = node.coord, .index = @intFromEnum(neighbor) },
    };
}

fn nextCell(self: *const Navmesh, node: NodeRef) ?nz.Vec3(i32) {
    const slot = node.chunk.next[self.internal.active][node.index];
    if (slot == no_next) return null;
    return node.chunk.graph.neighborCell(node.index, slot);
}

pub fn direction(self: *const Navmesh, planet: *const shared.Planet, position: nz.Vec3(f32)) ?nz.Vec3(f32) {
    const node = self.nodeNear(planet, position) orelse return null;
    const next_cell = self.nextCell(node) orelse return null;
    const next_node = self.nodeAt(next_cell) orelse return null;
    const delta = next_node.chunk.graph.cells.values()[next_node.index] - position;
    if (nz.vec.dot(delta, delta) <= 0.0001) return null;
    return nz.vec.normalize(delta);
}

fn nodeNear(self: *const Navmesh, planet: *const shared.Planet, position: nz.Vec3(f32)) ?NodeRef {
    return self.nodeNearCell(@intFromFloat(@floor(planet.surfacePoint(position))), position);
}

fn nodeNearCell(self: *const Navmesh, cell: nz.Vec3(i32), position: nz.Vec3(f32)) ?NodeRef {
    const down_step: nz.Vec3(i32) = @intFromFloat(@round(-nz.vec.normalize(position)));
    const candidates = [4]nz.Vec3(i32){ cell, cell + down_step, cell - down_step, cell + down_step + down_step };
    for (candidates) |candidate| {
        if (self.nodeAt(candidate)) |ref| return ref;
    }
    return null;
}

fn collectSeeds(self: *const Navmesh, out: *[shared.max_players]NodeRef) usize {
    var count: usize = 0;
    for (self.player_seeds[0..self.player_seed_count]) |seed| {
        const node = self.nodeNearCell(seed.cell, seed.position) orelse {
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
