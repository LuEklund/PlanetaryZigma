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
player_chunk: ?shared.planet.Chunk.Coord,
chunk_view_distance: i32,
meshes: std.AutoArrayHashMapUnmanaged(shared.planet.Chunk.Coord, Mesh),
job: ?RunningJob,
retired: std.ArrayList(RetiredChunk),

const RunningJob = struct {
    job: shared.planet.Chunk.Job(.renderable),
    id: shared.entity.Id,
};

const RetiredChunk = struct {
    mesh: Mesh,
    frame: u32,
};

pub fn init() Planet {
    return .{
        .id = .none,
        .radius = 0,
        .player_chunk = null,
        .chunk_view_distance = 0,
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
    self.player_chunk = null;
    self.chunk_view_distance = 0;
}

pub fn remove(self: *Planet, gpa: std.mem.Allocator, id: shared.entity.Id, frame: u32) !void {
    if (self.id == .none or self.id != id) return;
    for (self.meshes.values()) |mesh| {
        try self.retired.append(gpa, .{ .mesh = mesh, .frame = frame });
    }
    self.meshes.clearRetainingCapacity();
    self.id = .none;
    self.player_chunk = null;
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
    if (self.job) |_| return;
    if (self.id == .none) return;
    const position = if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position;
    const player_chunk: shared.planet.Chunk.Coord = .fromPosition(position);
    const chunk_view_distance: i32 = @max(world.chunk_view_distance, 1);
    if (self.player_chunk) |previous_player_chunk| {
        if (self.radius <= @as(u32, @intCast(shared.planet.Chunk.dim))) return;
        if (previous_player_chunk.eql(player_chunk) and self.chunk_view_distance == chunk_view_distance) return;
    }
    self.player_chunk = player_chunk;
    self.chunk_view_distance = chunk_view_distance;
    try self.startJob(gpa);
}

fn startJob(self: *Planet, gpa: std.mem.Allocator) !void {
    const player_chunk = self.player_chunk.?;
    const small = self.radius <= @as(u32, @intCast(shared.planet.Chunk.dim));
    const clamp: ?shared.planet.Chunk.Box = if (small) null else .{
        .min = player_chunk.offset(@splat(-self.chunk_view_distance)),
        .max = player_chunk.offset(@splat(self.chunk_view_distance)),
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
    self.job = .{
        .job = try .start(gpa, self.radius, try coords.toOwnedSlice(gpa)),
        .id = self.id,
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
    const streamed_player_chunk = self.player_chunk.?;

    var evicted: usize = 0;
    if (self.radius > @as(u32, @intCast(shared.planet.Chunk.dim))) {
        const live_position = if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position;
        const live_player_chunk: shared.planet.Chunk.Coord = .fromPosition(live_position);
        const live_chunk_view_distance: i32 = @max(world.chunk_view_distance, 1);
        var mesh_index: usize = self.meshes.count();
        while (mesh_index > 0) {
            mesh_index -= 1;
            const coord = self.meshes.keys()[mesh_index];
            if (!coord.within(live_player_chunk, live_chunk_view_distance)) {
                try self.retired.append(gpa, .{ .mesh = self.meshes.values()[mesh_index], .frame = frame });
                self.meshes.swapRemoveAt(mesh_index);
                evicted += 1;
            }
        }
        if (!live_player_chunk.eql(streamed_player_chunk) or live_chunk_view_distance != self.chunk_view_distance) self.player_chunk = null;
    }
    for (results.items) |*cpu_chunk| {
        if (cpu_chunk.indices.len == 0) continue;
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "planet-{d}-{d}-{d}-{d}", .{ @intFromEnum(running.id), cpu_chunk.coord.position[0], cpu_chunk.coord.position[1], cpu_chunk.coord.position[2] });
        const mesh = try Mesh.init(gpa, vma, name, device, Mesh.StaticVertex, cpu_chunk.vertices, cpu_chunk.indices, &.{.{ .index_start = 0, .index_count = @intCast(cpu_chunk.indices.len), .texture = .blank }});
        try self.meshes.put(gpa, cpu_chunk.coord, mesh);
    }
    std.log.debug("planet chunks: player_chunk={any}, added={d}, evicted={d}, active={d}", .{ streamed_player_chunk, results.items.len, evicted, self.meshes.count() });
}
