const Planet = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../system.zig");
const World = system.World;
const Mesh = @import("Vulkan/Mesh.zig");
const Vma = @import("Vulkan/Vma.zig");
const Device = @import("Vulkan/device.zig").Logical;
const FrameData = @import("Vulkan/FrameData.zig");

chunks: std.AutoHashMap(shared.entity.Id, Set),
job: ?RunningJob,
retired: std.ArrayList(RetiredChunk),

pub const Set = struct {
    radius: u32,
    center: ?nz.Vec3(i32),
    reach: i32,
    meshes: std.AutoArrayHashMapUnmanaged(nz.Vec3(i32), Mesh),
};

const RunningJob = struct {
    job: shared.planet.Chunk.Job(.renderable),
    id: shared.entity.Id,
    center: nz.Vec3(i32),
    reach: i32,
};

const RetiredChunk = struct {
    mesh: Mesh,
    frame: u32,
};

pub fn init(gpa: std.mem.Allocator) Planet {
    return .{
        .chunks = .init(gpa),
        .job = null,
        .retired = .empty,
    };
}

pub fn deinit(self: *Planet, gpa: std.mem.Allocator, vma: Vma) void {
    var set_iterator = self.chunks.valueIterator();
    while (set_iterator.next()) |set| {
        for (set.meshes.values()) |*mesh| mesh.deinit(gpa, vma);
        set.meshes.deinit(gpa);
    }
    self.chunks.deinit();
    for (self.retired.items) |*retired_chunk| retired_chunk.mesh.deinit(gpa, vma);
    self.retired.deinit(gpa);
    if (self.job) |running| running.job.join();
}

pub fn build(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32, frame: u32) !void {
    try self.remove(gpa, id, frame);
    try self.chunks.put(id, .{ .radius = radius, .center = null, .reach = 0, .meshes = .empty });
}

pub fn remove(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, frame: u32) !void {
    if (self.chunks.fetchRemove(id)) |entry| {
        var set = entry.value;
        for (set.meshes.values()) |mesh| {
            try self.retired.append(gpa, .{ .mesh = mesh, .frame = frame });
        }
        set.meshes.deinit(gpa);
    }
}

pub fn drainRetired(self: *Planet, gpa: std.mem.Allocator, vma: Vma, frame: u32) void {
    var retired_index: usize = self.retired.items.len;
    while (retired_index > 0) {
        retired_index -= 1;
        const retired_chunk = &self.retired.items[retired_index];
        if (frame >= retired_chunk.frame + FrameData.max_frames_inflight) {
            retired_chunk.mesh.deinit(gpa, vma);
            _ = self.retired.swapRemove(retired_index);
        }
    }
}

pub fn update(self: *Planet, gpa: std.mem.Allocator, world: *World) !void {
    if (self.job != null) return;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .planet) continue;
        const set = self.chunks.getPtr(entity.id) orelse continue;
        const center = centerFor(world, entity);
        const reach = reachFor(world, set.radius);
        if (set.center) |known| {
            if (set.radius <= @as(u32, @intCast(shared.planet.Chunk.dim))) continue;
            if (std.meta.eql(known, center) and set.reach == reach) continue;
        }
        set.center = center;
        set.reach = reach;
        try self.startJob(gpa, entity.id, set.radius, center, reach, set.meshes.keys());
        return;
    }
}

fn startJob(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32, center: nz.Vec3(i32), reach: i32, existing_coords: []const nz.Vec3(i32)) !void {
    const small = radius <= @as(u32, @intCast(shared.planet.Chunk.dim));
    const clamp: ?shared.planet.Chunk.Box = if (small) null else .{
        .min = center - @as(nz.Vec3(i32), @splat(reach)),
        .max = center + @as(nz.Vec3(i32), @splat(reach)),
    };
    const surface_coords = try shared.planet.Chunk.surfaceCoords(gpa, radius, clamp);
    defer gpa.free(surface_coords);
    var coords: std.ArrayList(nz.Vec3(i32)) = .empty;
    errdefer coords.deinit(gpa);
    for (surface_coords) |coord| {
        var already_built = false;
        for (existing_coords) |existing_coord| {
            if (std.meta.eql(existing_coord, coord)) {
                already_built = true;
                break;
            }
        }
        if (already_built) continue;
        try coords.append(gpa, coord);
    }
    self.job = .{
        .job = try .start(gpa, radius, try coords.toOwnedSlice(gpa)),
        .id = id,
        .center = center,
        .reach = reach,
    };
}

pub fn collect(self: *Planet, gpa: std.mem.Allocator, vma: Vma, device: Device, world: *World, frame: u32) !void {
    const running = self.job orelse return;
    var results = running.job.collect() orelse return;
    self.job = null;
    defer {
        for (results.items) |result| {
            gpa.free(result.vertices);
            gpa.free(result.indices);
        }
        results.deinit(gpa);
    }
    const set = self.chunks.getPtr(running.id) orelse return;
    const entity = world.getPtr(running.id) orelse return;

    var evicted: usize = 0;
    if (set.radius > @as(u32, @intCast(shared.planet.Chunk.dim))) {
        const live_center = centerFor(world, entity);
        const live_reach = reachFor(world, set.radius);
        const window_min = live_center - @as(nz.Vec3(i32), @splat(live_reach));
        const window_max = live_center + @as(nz.Vec3(i32), @splat(live_reach));
        var mesh_index: usize = set.meshes.count();
        while (mesh_index > 0) {
            mesh_index -= 1;
            const coord = set.meshes.keys()[mesh_index];
            if (@reduce(.Or, coord < window_min) or @reduce(.Or, coord > window_max)) {
                try self.retired.append(gpa, .{ .mesh = set.meshes.values()[mesh_index], .frame = frame });
                set.meshes.swapRemoveAt(mesh_index);
                evicted += 1;
            }
        }
        if (!std.meta.eql(live_center, running.center) or live_reach != running.reach) set.center = null;
    }
    for (results.items) |*cpu_chunk| {
        if (cpu_chunk.indices.len == 0) continue;
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}-{d}", .{ @intFromEnum(running.id), cpu_chunk.coord[0], cpu_chunk.coord[1], cpu_chunk.coord[2] });
        const mesh = try Mesh.init(gpa, vma, name, device, Mesh.StaticVertex, cpu_chunk.vertices, cpu_chunk.indices, &.{.{ .index_start = 0, .index_count = @intCast(cpu_chunk.indices.len), .texture = .blank }});
        try set.meshes.put(gpa, cpu_chunk.coord, mesh);
    }
    std.log.debug("planet chunks: center={any}, added={d}, evicted={d}, active={d}", .{ running.center, results.items.len, evicted, set.meshes.count() });
}

fn reachFor(world: *World, radius: u32) i32 {
    const range = shared.planet.Chunk.range(radius);
    return std.math.clamp(world.chunk_view_distance, 1, range.max - range.min + 1);
}

fn centerFor(world: *World, planet_entity: *const World.Entity) nz.Vec3(i32) {
    const position = if (world.controller.free_camera) world.camera.transform.position else if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position;
    const local = position - planet_entity.transform.position;
    const chunk_size: f32 = @floatFromInt(shared.planet.Chunk.dim);
    return .{
        @intFromFloat(@floor(local[0] / (planet_entity.transform.scale[0] * chunk_size))),
        @intFromFloat(@floor(local[1] / (planet_entity.transform.scale[1] * chunk_size))),
        @intFromFloat(@floor(local[2] / (planet_entity.transform.scale[2] * chunk_size))),
    };
}
