const Planet = @This();

const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf_math = @import("sdf.zig");

pub const Chunk = @import("Chunk.zig");

pub const cell_margin = 1;
pub const radius_min: u32 = 15;
pub const dev_radius_min: u32 = 1000;

planet_radius: u32,
chunks: std.AutoArrayHashMapUnmanaged(Chunk.Coord, Entry),
job: ?RunningJob,
uploads: std.ArrayList(Upload),
removes: std.ArrayList(Chunk.Coord),

pub const Entry = struct {
    raw: Chunk.Raw,
    mesh: Chunk.Mesh,
    nav: Chunk.NavGraph,
};

pub const Upload = struct {
    coord: Chunk.Coord,
    vertices: []const Chunk.Mesh.Vertex,
    indices: []const u32,
};

const RunningJob = struct {
    job: Chunk.Job,
    planet_radius: u32,
};

const job_batch_max: usize = 16;

pub const empty: Planet = .{
    .planet_radius = 0,
    .chunks = .empty,
    .job = null,
    .uploads = .empty,
    .removes = .empty,
};

pub fn deinit(self: *Planet, gpa: std.mem.Allocator) void {
    if (self.job) |running| running.job.join();
    for (self.chunks.values()) |*chunk_entry| {
        chunk_entry.raw.deinit(gpa);
        chunk_entry.mesh.deinit(gpa);
        chunk_entry.nav.deinit(gpa);
    }
    self.chunks.deinit(gpa);
    self.uploads.deinit(gpa);
    self.removes.deinit(gpa);
}

pub fn radiusFloat(self: *const Planet) f32 {
    return @floatFromInt(self.planet_radius);
}

pub fn sync(self: *Planet, gpa: std.mem.Allocator, planet_radius: u32) !void {
    if (planet_radius == self.planet_radius) return;
    try self.dropAllChunks(gpa);
    self.planet_radius = planet_radius;
}

pub fn clearOutboxes(self: *Planet) void {
    self.uploads.clearRetainingCapacity();
    self.removes.clearRetainingCapacity();
}

pub fn update(self: *Planet, gpa: std.mem.Allocator, anchors: []const nz.Vec3(f32), view_distance: i32) !void {
    if (self.planet_radius == 0) return;

    const small = self.planet_radius <= @as(u32, @intCast(Chunk.dim));
    try self.collectJob(gpa, anchors, view_distance, small);

    if (!small) {
        var chunk_index: usize = self.chunks.count();
        while (chunk_index > 0) {
            chunk_index -= 1;
            const coord = self.chunks.keys()[chunk_index];
            const kept = for (anchors) |anchor| {
                if (coord.within(.fromPosition(anchor), view_distance)) break true;
            } else false;
            if (kept) continue;
            try self.removes.append(gpa, coord);
            var chunk_entry = self.chunks.values()[chunk_index];
            chunk_entry.raw.deinit(gpa);
            chunk_entry.mesh.deinit(gpa);
            chunk_entry.nav.deinit(gpa);
            self.chunks.swapRemoveAt(chunk_index);
        }
    }

    if (self.job == null) try self.startJob(gpa, anchors, view_distance, small);
}

fn collectJob(self: *Planet, gpa: std.mem.Allocator, anchors: []const nz.Vec3(f32), view_distance: i32, small: bool) !void {
    const running = self.job orelse return;
    var results = running.job.collect() orelse return;
    self.job = null;
    defer results.deinit(gpa);

    const stale = running.planet_radius != self.planet_radius;
    var inserted: usize = 0;
    var freed: usize = 0;
    defer std.log.debug("planet collectJob: inserted {d} freed {d}", .{ inserted, freed });
    for (results.items) |*result| {
        const in_window = small or for (anchors) |anchor| {
            if (result.coord.within(.fromPosition(anchor), view_distance)) break true;
        } else false;
        if (stale or !in_window) {
            result.raw.deinit(gpa);
            gpa.free(result.vertices);
            gpa.free(result.indices);
            result.nav.deinit(gpa);
            freed += 1;
            continue;
        }
        const slot = try self.chunks.getOrPut(gpa, result.coord);
        if (slot.found_existing) {
            result.raw.deinit(gpa);
            gpa.free(result.vertices);
            gpa.free(result.indices);
            result.nav.deinit(gpa);
            freed += 1;
            continue;
        }
        slot.value_ptr.* = .{ .raw = result.raw, .mesh = .{ .vertices = result.vertices, .indices = result.indices }, .nav = result.nav };
        inserted += 1;
        if (result.indices.len != 0) {
            try self.uploads.append(gpa, .{ .coord = result.coord, .vertices = result.vertices, .indices = result.indices });
        }
    }
}

fn startJob(self: *Planet, gpa: std.mem.Allocator, anchors: []const nz.Vec3(f32), view_distance: i32, small: bool) !void {
    var missing: std.ArrayList(Chunk.Coord) = .empty;
    errdefer missing.deinit(gpa);

    if (small) {
        const window_coords = try Chunk.coords(gpa, self.planet_radius, null);
        defer gpa.free(window_coords);
        for (window_coords) |coord| {
            if (!self.chunks.contains(coord)) try missing.append(gpa, coord);
        }
    } else for (anchors) |anchor| {
        const anchor_chunk: Chunk.Coord = .fromPosition(anchor);
        const clamp: Chunk.Box = .{
            .min = anchor_chunk.offset(@splat(-view_distance)),
            .max = anchor_chunk.offset(@splat(view_distance)),
        };
        const window_coords = try Chunk.coords(gpa, self.planet_radius, clamp);
        defer gpa.free(window_coords);
        for (window_coords) |coord| {
            if (self.chunks.contains(coord)) continue;
            const seen = for (missing.items) |queued| {
                if (queued.eql(coord)) break true;
            } else false;
            if (seen) continue;
            try missing.append(gpa, coord);
        }
    }

    if (missing.items.len == 0) {
        missing.deinit(gpa);
        return;
    }
    if (missing.items.len > job_batch_max) {
        std.sort.pdq(Chunk.Coord, missing.items, anchors, closerToAnchors);
        missing.shrinkRetainingCapacity(job_batch_max);
    }
    std.log.debug("planet startJob: {d} coords", .{missing.items.len});
    self.job = .{
        .job = try .start(gpa, self.planet_radius, try missing.toOwnedSlice(gpa)),
        .planet_radius = self.planet_radius,
    };
}

fn closerToAnchors(anchors: []const nz.Vec3(f32), a: Chunk.Coord, b: Chunk.Coord) bool {
    return anchorDistanceSquared(anchors, a) < anchorDistanceSquared(anchors, b);
}

fn anchorDistanceSquared(anchors: []const nz.Vec3(f32), coord: Chunk.Coord) i32 {
    var best: i32 = std.math.maxInt(i32);
    for (anchors) |anchor| {
        const anchor_chunk: Chunk.Coord = .fromPosition(anchor);
        const delta = coord.position - anchor_chunk.position;
        best = @min(best, @reduce(.Add, delta * delta));
    }
    return best;
}

fn dropAllChunks(self: *Planet, gpa: std.mem.Allocator) !void {
    for (self.chunks.keys(), self.chunks.values()) |coord, *chunk_entry| {
        try self.removes.append(gpa, coord);
        chunk_entry.raw.deinit(gpa);
        chunk_entry.mesh.deinit(gpa);
        chunk_entry.nav.deinit(gpa);
    }
    self.chunks.clearRetainingCapacity();
}

pub fn sdf(self: *const Planet, position: nz.Vec3(f32)) f32 {
    return sdf_math.sdf(position, self.radiusFloat());
}

pub fn sample(self: *const Planet, position: nz.Vec3(f32)) f32 {
    return sdf_math.sampled(position, self.radiusFloat());
}

pub fn gradient(self: *const Planet, position: nz.Vec3(f32)) nz.Vec3(f32) {
    return sdf_math.gradient(position, self.radiusFloat());
}

pub fn surfacePoint(self: *const Planet, direction: nz.Vec3(f32)) nz.Vec3(f32) {
    const planet_radius = self.radiusFloat();
    const unit_direction = nz.vec.normalize(direction);
    var inner: f32 = @max(planet_radius - sdf_math.noise_amplitude - cell_margin, 0);
    var outer: f32 = planet_radius + sdf_math.noise_amplitude + cell_margin;
    for (0..24) |_| {
        const middle = (inner + outer) * 0.5;
        if (sdf_math.sdf(nz.vec.scale(unit_direction, middle), planet_radius) < 0) inner = middle else outer = middle;
    }
    return nz.vec.scale(unit_direction, (inner + outer) * 0.5);
}

pub fn surfacePointNear(self: *const Planet, direction: nz.Vec3(f32), min_distance: f32, max_distance: f32, random: std.Random) nz.Vec3(f32) {
    const unit_direction = nz.vec.normalize(direction);
    const reference: nz.Vec3(f32) = if (@abs(unit_direction[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const tangent_a = nz.vec.normalize(nz.vec.cross(unit_direction, reference));
    const tangent_b = nz.vec.cross(unit_direction, tangent_a);
    const spin = random.float(f32) * std.math.tau;
    const tangent = nz.vec.scale(tangent_a, @cos(spin)) + nz.vec.scale(tangent_b, @sin(spin));
    const distance = min_distance + random.float(f32) * (max_distance - min_distance);
    const angle = distance / self.radiusFloat();
    const tilted = nz.vec.scale(unit_direction, @cos(angle)) + nz.vec.scale(tangent, @sin(angle));
    return self.surfacePoint(tilted);
}

pub fn surfaceTransform(self: *const Planet, direction: nz.Vec3(f32), hover: f32) nz.Transform3D(f32) {
    const surface = self.surfacePoint(direction);
    const surface_up = up(surface) orelse nz.Vec3(f32){ 0, 1, 0 };
    const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
    const dot = std.math.clamp(nz.vec.dot(default_up, surface_up), -1.0, 1.0);
    const rotation: nz.quat.Hamiltonian(f32) = if (dot >= 0.9999) .identity else rot: {
        const axis = if (dot > -0.9999)
            nz.vec.normalize(nz.vec.cross(default_up, surface_up))
        else
            nz.Vec3(f32){ 1, 0, 0 };
        break :rot .angleAxis(std.math.acos(dot), axis);
    };
    return .{
        .position = surface + nz.vec.scale(surface_up, hover),
        .rotation = rotation,
    };
}

pub fn up(position: nz.Vec3(f32)) ?nz.Vec3(f32) {
    const distance = nz.vec.length(position);
    return if (distance > 0.001) nz.vec.scale(position, 1.0 / distance) else null;
}

pub fn surfaceLaunch(position: nz.Vec3(f32), direction: nz.Vec3(f32), angle: f32, speed: f32) nz.Vec3(f32) {
    const surface_up = up(position) orelse nz.Vec3(f32){ 0, 1, 0 };
    const flat_direction = direction - nz.vec.scale(surface_up, nz.vec.dot(direction, surface_up));
    const heading = if (nz.vec.length(flat_direction) > 0.001)
        nz.vec.normalize(flat_direction)
    else heading: {
        const helper: nz.Vec3(f32) = if (@abs(surface_up[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        break :heading nz.vec.normalize(nz.vec.cross(surface_up, helper));
    };
    const launch = nz.vec.scale(heading, @cos(angle)) + nz.vec.scale(surface_up, @sin(angle));
    return nz.vec.scale(launch, speed);
}

test surfacePoint {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    for ([_]u32{ 8, 15, 60, 100 }) |planet_radius| {
        var test_planet: Planet = .empty;
        test_planet.planet_radius = planet_radius;
        const radius_float = test_planet.radiusFloat();
        for (0..50) |_| {
            const direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
            const point = test_planet.surfacePoint(direction);
            try std.testing.expect(@abs(sdf_math.sdf(point, radius_float)) < 0.001);
            const near = test_planet.surfacePointNear(direction, 15, 25, random);
            try std.testing.expect(@abs(sdf_math.sdf(near, radius_float)) < 0.001);
        }
    }
}
