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

id: shared.entity.Id,
radius: u32,
center: ?shared.planet.Chunk.Coord,
reach: i32,
meshes: std.AutoArrayHashMapUnmanaged(shared.planet.Chunk.Coord, Mesh),
job: ?RunningJob,
retired: std.ArrayList(RetiredChunk),

const RunningJob = struct {
    job: shared.planet.Chunk.Job(.renderable),
    id: shared.entity.Id,
    center: shared.planet.Chunk.Coord,
    reach: i32,
};

const RetiredChunk = struct {
    mesh: Mesh,
    frame: u32,
};

pub fn init() Planet {
    return .{
        .id = .none,
        .radius = 0,
        .center = null,
        .reach = 0,
        .meshes = .empty,
        .job = null,
        .retired = .empty,
    };
}

pub fn deinit(self: *Planet, gpa: std.mem.Allocator, vma: Vma) void {
    for (self.meshes.values()) |*mesh| mesh.deinit(gpa, vma);
    self.meshes.deinit(gpa);
    for (self.retired.items) |*retired_chunk| retired_chunk.mesh.deinit(gpa, vma);
    self.retired.deinit(gpa);
    if (self.job) |running| running.job.join();
}

pub fn build(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32, frame: u32) !void {
    try self.remove(gpa, self.id, frame);
    self.id = id;
    self.radius = radius;
    self.center = null;
    self.reach = 0;
}

pub fn remove(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, frame: u32) !void {
    if (self.id == .none or self.id != id) return;
    for (self.meshes.values()) |mesh| {
        try self.retired.append(gpa, .{ .mesh = mesh, .frame = frame });
    }
    self.meshes.clearRetainingCapacity();
    self.id = .none;
    self.center = null;
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
    const entity = world.getPtr(self.id) orelse return;
    const center = centerFor(world, entity);
    const reach = reachFor(world, self.radius);
    if (self.center) |known| {
        if (self.radius <= @as(u32, @intCast(shared.planet.Chunk.dim))) return;
        if (known.eql(center) and self.reach == reach) return;
    }
    self.center = center;
    self.reach = reach;
    try self.startJob(gpa, self.id, self.radius, center, reach, self.meshes.keys());
}

fn startJob(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32, center: shared.planet.Chunk.Coord, reach: i32, existing_coords: []const shared.planet.Chunk.Coord) !void {
    const small = radius <= @as(u32, @intCast(shared.planet.Chunk.dim));
    const clamp: ?shared.planet.Chunk.Box = if (small) null else .{
        .min = center.offset(@splat(-reach)),
        .max = center.offset(@splat(reach)),
    };
    const window_coords = try shared.planet.Chunk.coords(gpa, radius, clamp);
    defer gpa.free(window_coords);
    var coords: std.ArrayList(shared.planet.Chunk.Coord) = .empty;
    errdefer coords.deinit(gpa);
    for (window_coords) |coord| {
        var already_built = false;
        for (existing_coords) |existing_coord| {
            if (existing_coord.eql(coord)) {
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
    if (self.id != running.id) return;
    const entity = world.getPtr(running.id) orelse return;

    var evicted: usize = 0;
    if (self.radius > @as(u32, @intCast(shared.planet.Chunk.dim))) {
        const live_center = centerFor(world, entity);
        const live_reach = reachFor(world, self.radius);
        var mesh_index: usize = self.meshes.count();
        while (mesh_index > 0) {
            mesh_index -= 1;
            const coord = self.meshes.keys()[mesh_index];
            if (!coord.within(live_center, live_reach)) {
                try self.retired.append(gpa, .{ .mesh = self.meshes.values()[mesh_index], .frame = frame });
                self.meshes.swapRemoveAt(mesh_index);
                evicted += 1;
            }
        }
        if (!live_center.eql(running.center) or live_reach != running.reach) self.center = null;
    }
    for (results.items) |*cpu_chunk| {
        if (cpu_chunk.indices.len == 0) continue;
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}-{d}", .{ @intFromEnum(running.id), cpu_chunk.coord.position[0], cpu_chunk.coord.position[1], cpu_chunk.coord.position[2] });
        const mesh = try Mesh.init(gpa, vma, name, device, Mesh.StaticVertex, cpu_chunk.vertices, cpu_chunk.indices, &.{.{ .index_start = 0, .index_count = @intCast(cpu_chunk.indices.len), .texture = .blank }});
        try self.meshes.put(gpa, cpu_chunk.coord, mesh);
    }
    std.log.debug("planet chunks: center={any}, added={d}, evicted={d}, active={d}", .{ running.center, results.items.len, evicted, self.meshes.count() });
}

fn reachFor(world: *World, radius: u32) i32 {
    const range = shared.planet.Chunk.range(radius);
    return std.math.clamp(world.chunk_view_distance, 1, range.max - range.min + 1);
}

fn centerFor(world: *World, planet_entity: *const World.Entity) shared.planet.Chunk.Coord {
    const position = if (world.controller.free_camera) world.camera.transform.position else if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position;
    const local = position - planet_entity.transform.position;
    const chunk_size: f32 = @floatFromInt(shared.planet.Chunk.dim);
    return .{ .position = .{
        @intFromFloat(@floor(local[0] / (planet_entity.transform.scale[0] * chunk_size))),
        @intFromFloat(@floor(local[1] / (planet_entity.transform.scale[1] * chunk_size))),
        @intFromFloat(@floor(local[2] / (planet_entity.transform.scale[2] * chunk_size))),
    } };
}
