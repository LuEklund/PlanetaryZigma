const Planet = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Mesh = @import("Vulkan/Mesh.zig");
const Vma = @import("Vulkan/Vma.zig");
const Device = @import("Vulkan/device.zig").Logical;
const FrameData = @import("Vulkan/FrameData.zig");

planet_id: shared.entity.Id,
radius: u32,
meshes: std.AutoArrayHashMapUnmanaged(shared.planet.Chunk.Coord, ?Mesh),
job: ?RunningJob,
retired: std.ArrayList(RetiredChunk),

const RunningJob = struct {
    job: shared.planet.Chunk.Job(.renderable),
    planet_id: shared.entity.Id,
};

const RetiredChunk = struct {
    mesh: Mesh,
    frame: u32,
};

const job_batch_max: usize = 16;

pub fn init() Planet {
    return .{
        .planet_id = .none,
        .radius = 0,
        .meshes = .empty,
        .job = null,
        .retired = .empty,
    };
}

pub fn deinit(self: *Planet, gpa: std.mem.Allocator, vma: Vma) void {
    for (self.meshes.values()) |*maybe_mesh| if (maybe_mesh.*) |*mesh| mesh.deinit(gpa, vma);
    self.meshes.deinit(gpa);
    for (self.retired.items) |*retired_chunk| retired_chunk.mesh.deinit(gpa, vma);
    self.retired.deinit(gpa);
    if (self.job) |running| running.job.join();
}

pub fn build(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, radius: u32, frame: u32) !void {
    try self.remove(gpa, self.planet_id, frame);
    self.planet_id = id;
    self.radius = radius;
}

pub fn remove(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, frame: u32) !void {
    if (self.planet_id == .none or self.planet_id != id) return;
    for (self.meshes.values()) |maybe_mesh| {
        const mesh = maybe_mesh orelse continue;
        try self.retired.append(gpa, .{ .mesh = mesh, .frame = frame });
    }
    self.meshes.clearRetainingCapacity();
    self.planet_id = .none;
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

pub fn update(self: *Planet, gpa: std.mem.Allocator, anchor_position: nz.Vec3(f32), view_distance: i32) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    if (self.job) |_| return;
    if (self.planet_id == .none) return;
    const player_chunk: shared.planet.Chunk.Coord = .fromPosition(anchor_position);
    try self.startJob(gpa, player_chunk, view_distance);
}

fn startJob(self: *Planet, gpa: std.mem.Allocator, player_chunk: shared.planet.Chunk.Coord, chunk_view_distance: i32) !void {
    const small = self.radius <= @as(u32, @intCast(shared.planet.Chunk.dim));
    const clamp: ?shared.planet.Chunk.Box = if (small) null else .{
        .min = player_chunk.offset(@splat(-chunk_view_distance)),
        .max = player_chunk.offset(@splat(chunk_view_distance)),
    };
    const window_coords = try shared.planet.Chunk.coords(gpa, self.radius, clamp);
    defer gpa.free(window_coords);
    var coords: std.ArrayList(shared.planet.Chunk.Coord) = .empty;
    errdefer coords.deinit(gpa);
    for (window_coords) |coord| {
        for (self.meshes.keys()) |existing_coord| {
            if (existing_coord.eql(coord)) break;
        } else try coords.append(gpa, coord);
    }
    if (coords.items.len == 0) return;
    if (coords.items.len > job_batch_max) {
        std.sort.pdq(shared.planet.Chunk.Coord, coords.items, player_chunk, closerToPlayer);
        coords.shrinkRetainingCapacity(job_batch_max);
    }
    self.job = .{
        .job = try .start(gpa, self.radius, try coords.toOwnedSlice(gpa)),
        .planet_id = self.planet_id,
    };
}
fn closerToPlayer(player_chunk: shared.planet.Chunk.Coord, a: shared.planet.Chunk.Coord, b: shared.planet.Chunk.Coord) bool {
    const delta_a = a.position - player_chunk.position;
    const delta_b = b.position - player_chunk.position;
    return @reduce(.Add, delta_a * delta_a) < @reduce(.Add, delta_b * delta_b);
}

pub fn collect(self: *Planet, gpa: std.mem.Allocator, vma: Vma, device: Device, anchor_position: nz.Vec3(f32), view_distance: i32, frame: u32) !void {
    const running = self.job orelse return;
    var results = running.job.collect() orelse return;
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    self.job = null;
    defer {
        for (results.items) |result| {
            gpa.free(result.vertices);
            gpa.free(result.indices);
        }
        results.deinit(gpa);
    }
    if (self.planet_id != running.planet_id) return;

    var evicted: usize = 0;
    if (self.radius > @as(u32, @intCast(shared.planet.Chunk.dim))) {
        const live_player_chunk: shared.planet.Chunk.Coord = .fromPosition(anchor_position);
        var mesh_index: usize = self.meshes.count();
        while (mesh_index > 0) {
            mesh_index -= 1;
            const coord = self.meshes.keys()[mesh_index];
            if (!coord.within(live_player_chunk, view_distance)) {
                if (self.meshes.values()[mesh_index]) |mesh| {
                    try self.retired.append(gpa, .{ .mesh = mesh, .frame = frame });
                }
                self.meshes.swapRemoveAt(mesh_index);
                evicted += 1;
            }
        }
    }
    for (results.items) |*cpu_chunk| {
        if (cpu_chunk.indices.len == 0) {
            try self.meshes.put(gpa, cpu_chunk.coord, null);
            continue;
        }
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}-{d}", .{ @intFromEnum(running.planet_id), cpu_chunk.coord.position[0], cpu_chunk.coord.position[1], cpu_chunk.coord.position[2] });
        const mesh = try Mesh.init(gpa, vma, name, device, Mesh.StaticVertex, cpu_chunk.vertices, cpu_chunk.indices, &.{.{ .index_start = 0, .index_count = @intCast(cpu_chunk.indices.len), .texture = .blank }});
        try self.meshes.put(gpa, cpu_chunk.coord, mesh);
    }
    // std.log.debug("planet chunks: added={d}, evicted={d}, active={d}", .{ results.items.len, evicted, self.meshes.count() });
}
