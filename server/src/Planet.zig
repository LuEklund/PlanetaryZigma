const Planet = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("World.zig");
const Physics = @import("system/Physics.zig");

radius: f32,
chunks: std.ArrayList(PlanetChunk),
job: ?shared.planet.Chunk.Job(.logical),
ready: std.ArrayList(shared.planet.Chunk.Job(.logical).Result),

const stream_reach: i32 = 1;
const evict_reach: i32 = 2;
const job_batch_max: usize = 16;
const body_budget: u32 = 2;

pub const PlanetChunk = struct {
    coord: shared.planet.Chunk.Coord,
    mesh: Physics.Collider.Mesh,
    body_id: ?Physics.c.b3BodyId = null,
};

pub fn deinit(self: *Planet, gpa: std.mem.Allocator) void {
    self.clear(gpa, null);
    self.chunks.deinit(gpa);
    self.ready.deinit(gpa);
}

pub fn clear(self: *Planet, gpa: std.mem.Allocator, physics: ?*Physics) void {
    for (self.chunks.items) |chunk| {
        if (physics) |live_physics| {
            if (chunk.body_id) |body_id| live_physics.destroyBody(body_id);
        }
        gpa.free(chunk.mesh.indices);
        gpa.free(chunk.mesh.vertices);
    }
    self.chunks.clearRetainingCapacity();
    for (self.ready.items) |result| {
        gpa.free(result.vertices);
        gpa.free(result.indices);
    }
    self.ready.clearRetainingCapacity();
}

pub fn addChunk(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, coord: shared.planet.Chunk.Coord, mesh: Physics.Collider.Mesh) !void {
    errdefer {
        gpa.free(mesh.indices);
        gpa.free(mesh.vertices);
    }
    const body_id = try physics.createStaticMeshBody(mesh);
    errdefer physics.destroyBody(body_id);
    try self.chunks.append(gpa, .{ .coord = coord, .mesh = mesh, .body_id = body_id });
}

pub fn removeChunk(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, index: usize) void {
    const chunk = self.chunks.swapRemove(index);
    if (chunk.body_id) |body_id| physics.destroyBody(body_id);
    gpa.free(chunk.mesh.indices);
    gpa.free(chunk.mesh.vertices);
}

pub fn joinJob(self: *Planet) void {
    const job = self.job orelse return;
    job.join();
    self.job = null;
}

pub fn ensureChunk(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, coord: shared.planet.Chunk.Coord) !void {
    const radius: u32 = @intFromFloat(self.radius);
    for (self.chunks.items) |chunk| {
        if (chunk.coord.eql(coord)) return;
    }
    const chunk_mesh = try shared.planet.Planet(.logical).initChunk(gpa, radius, coord);
    if (chunk_mesh.indices.len == 0) {
        errdefer chunk_mesh.deinit(gpa);
        try self.chunks.append(gpa, .{ .coord = coord, .mesh = .{ .indices = chunk_mesh.indices, .vertices = chunk_mesh.vertices }, .body_id = null });
        return;
    }
    try self.addChunk(gpa, physics, coord, .{ .indices = chunk_mesh.indices, .vertices = chunk_mesh.vertices });
}

pub fn stream(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, entities: []World.Entity) !void {
    const radius: u32 = @intFromFloat(self.radius);

    try self.collectJob(gpa);
    try self.integrateReady(gpa, physics);

    var missing: std.ArrayList(shared.planet.Chunk.Coord) = .empty;
    defer missing.deinit(gpa);
    for (entities) |*entity| {
        if (!shared.entity.hasCollider(entity.kind)) continue;
        if (entity.collider.motion_type != .dynamic) continue;
        const center: shared.planet.Chunk.Coord = .fromPosition(entity.transform.position);
        try self.ensureChunk(gpa, physics, center);
        var x: i32 = -stream_reach;
        while (x <= stream_reach) : (x += 1) {
            var y: i32 = -stream_reach;
            while (y <= stream_reach) : (y += 1) {
                var z: i32 = -stream_reach;
                while (z <= stream_reach) : (z += 1) {
                    if (missing.items.len >= job_batch_max) continue;
                    const coord = center.offset(.{ x, y, z });
                    if (coord.eql(center)) continue;
                    if (self.chunkKnown(coord)) continue;
                    var queued = false;
                    for (missing.items) |missing_coord| {
                        if (missing_coord.eql(coord)) {
                            queued = true;
                            break;
                        }
                    }
                    if (queued) continue;
                    try missing.append(gpa, coord);
                }
            }
        }
    }
    if (self.job == null and missing.items.len > 0) {
        self.job = try .start(gpa, radius, try missing.toOwnedSlice(gpa));
    }
    var index: usize = self.chunks.items.len;
    evict: while (index > 0) {
        index -= 1;
        const coord = self.chunks.items[index].coord;
        for (entities) |*entity| {
            if (!shared.entity.hasCollider(entity.kind)) continue;
            if (entity.collider.motion_type != .dynamic) continue;
            if (coord.within(.fromPosition(entity.transform.position), evict_reach)) continue :evict;
        }
        self.removeChunk(gpa, physics, index);
    }
}

fn collectJob(self: *Planet, gpa: std.mem.Allocator) !void {
    const job = self.job orelse return;
    const job_radius = job.state.radius;
    var results = job.collect() orelse return;
    self.job = null;
    defer results.deinit(gpa);
    const radius: u32 = @intFromFloat(self.radius);
    if (job_radius == radius) {
        try self.ready.appendSlice(gpa, results.items);
    } else {
        for (results.items) |result| {
            gpa.free(result.vertices);
            gpa.free(result.indices);
        }
    }
}

fn integrateReady(self: *Planet, gpa: std.mem.Allocator, physics: *Physics) !void {
    var bodies_created: u32 = 0;
    while (bodies_created < body_budget) {
        const result = self.ready.pop() orelse return;
        var duplicate = false;
        for (self.chunks.items) |chunk| {
            if (chunk.coord.eql(result.coord)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            gpa.free(result.vertices);
            gpa.free(result.indices);
            continue;
        }
        if (result.indices.len == 0) {
            try self.chunks.append(gpa, .{ .coord = result.coord, .mesh = .{ .indices = result.indices, .vertices = result.vertices }, .body_id = null });
            continue;
        }
        try self.addChunk(gpa, physics, result.coord, .{ .indices = result.indices, .vertices = result.vertices });
        bodies_created += 1;
    }
}

fn chunkKnown(self: *Planet, coord: shared.planet.Chunk.Coord) bool {
    for (self.chunks.items) |chunk| {
        if (chunk.coord.eql(coord)) return true;
    }
    for (self.ready.items) |result| {
        if (result.coord.eql(coord)) return true;
    }
    if (self.job) |job| {
        for (job.state.coords) |job_coord| {
            if (job_coord.eql(coord)) return true;
        }
    }
    return false;
}
