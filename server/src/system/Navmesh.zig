const Navmesh = @This();

const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");
const nz = shared.numz;

chunks: std.AutoArrayHashMapUnmanaged(shared.Planet.Chunk.Coord, shared.Planet.Chunk.Navmesh),
player_seed_positions: [shared.max_players]nz.Vec3(f32),
player_seed_count: usize,

const rebuild_distance: f32 = 8;

pub const empty: Navmesh = .{
    .chunks = .empty,
    .player_seed_positions = undefined,
    .player_seed_count = 0,
};

pub fn deinit(self: *Navmesh, gpa: std.mem.Allocator) void {
    for (self.chunks.values()) |*nav| nav.deinit(gpa);
    self.chunks.deinit(gpa);
}

pub fn update(self: *Navmesh, world: *World) !void {
    if (!self.needsRebuild(world)) return;
    const gpa = world.gpa;
    const planet = &world.planet;
    var chunk_index: usize = self.chunks.count();
    while (chunk_index > 0) {
        chunk_index -= 1;
        if (planet.chunks.contains(self.chunks.keys()[chunk_index])) continue;
        self.chunks.values()[chunk_index].deinit(gpa);
        self.chunks.swapRemoveAt(chunk_index);
    }
    for (planet.chunks.keys(), planet.chunks.values()) |coord, *chunk_entry| {
        if (self.chunks.contains(coord)) continue;
        try self.chunks.put(gpa, coord, try shared.Planet.Chunk.generate(.navmesh, gpa, &chunk_entry.raw, planet.planet_radius));
    }

    self.player_seed_count = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        self.player_seed_positions[self.player_seed_count] = player.transform.position;
        self.player_seed_count += 1;
    }
}

fn needsRebuild(self: *Navmesh, world: *World) bool {
    if (self.chunks.count() == 0 and world.planet.chunks.count() != 0) return true;
    var player_index: usize = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        const delta = player.transform.position - self.player_seed_positions[player_index];
        if (nz.vec.dot(delta, delta) > rebuild_distance * rebuild_distance) return true;
        player_index += 1;
    }
    return player_index != self.player_seed_count;
}
