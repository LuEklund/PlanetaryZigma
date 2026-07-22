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
    coord: nz.Vec3(i32),
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

pub fn addChunk(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, coord: nz.Vec3(i32), mesh: Physics.Collider.Mesh) !void {
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

pub fn ensureChunk(self: *Planet, gpa: std.mem.Allocator, physics: *Physics, coord: nz.Vec3(i32)) !void {
    const radius: u32 = @intFromFloat(self.radius);
    if (shared.planet.Chunk.classify(radius, coord) != .surface) return;
    for (self.chunks.items) |chunk| {
        if (std.meta.eql(chunk.coord, coord)) return;
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

    var missing: std.ArrayList(nz.Vec3(i32)) = .empty;
    defer missing.deinit(gpa);
    for (entities) |*entity| {
        if (!shared.entity.hasCollider(entity.kind)) continue;
        if (entity.collider.motion_type != .dynamic) continue;
        const center = shared.planet.Chunk.fromPosition(entity.transform.position);
        try self.ensureChunk(gpa, physics, center);
        var x: i32 = -stream_reach;
        while (x <= stream_reach) : (x += 1) {
            var y: i32 = -stream_reach;
            while (y <= stream_reach) : (y += 1) {
                var z: i32 = -stream_reach;
                while (z <= stream_reach) : (z += 1) {
                    if (missing.items.len >= job_batch_max) continue;
                    const coord = center + nz.Vec3(i32){ x, y, z };
                    if (std.meta.eql(coord, center)) continue;
                    if (shared.planet.Chunk.classify(radius, coord) != .surface) continue;
                    if (self.chunkKnown(coord)) continue;
                    var queued = false;
                    for (missing.items) |missing_coord| {
                        if (std.meta.eql(missing_coord, coord)) {
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
            const delta = coord - shared.planet.Chunk.fromPosition(entity.transform.position);
            const within_low = @reduce(.And, delta >= @as(nz.Vec3(i32), @splat(-evict_reach)));
            const within_high = @reduce(.And, delta <= @as(nz.Vec3(i32), @splat(evict_reach)));
            if (within_low and within_high) continue :evict;
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
            if (std.meta.eql(chunk.coord, result.coord)) {
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

fn chunkKnown(self: *Planet, coord: nz.Vec3(i32)) bool {
    for (self.chunks.items) |chunk| {
        if (std.meta.eql(chunk.coord, coord)) return true;
    }
    for (self.ready.items) |result| {
        if (std.meta.eql(result.coord, coord)) return true;
    }
    if (self.job) |job| {
        for (job.state.coords) |job_coord| {
            if (std.meta.eql(job_coord, coord)) return true;
        }
    }
    return false;
}
