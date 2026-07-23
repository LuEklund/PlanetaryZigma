const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const planet = @import("root.zig");

pub const dim: i32 = 32;

pub const Range = struct { min: i32, max: i32 };

pub const Coord = struct {
    position: nz.Vec3(i32),

    pub fn fromPosition(position: nz.Vec3(f32)) Coord {
        return .{ .position = @intFromFloat(@floor(position / @as(nz.Vec3(f32), @splat(@floatFromInt(dim))))) };
    }

    pub fn offset(self: Coord, delta: nz.Vec3(i32)) Coord {
        return .{ .position = self.position + delta };
    }

    pub fn eql(self: Coord, other: Coord) bool {
        return @reduce(.And, self.position == other.position);
    }

    pub fn within(self: Coord, center: Coord, reach: i32) bool {
        const difference = self.position - center.position;
        return @reduce(.And, difference >= @as(nz.Vec3(i32), @splat(-reach))) and @reduce(.And, difference <= @as(nz.Vec3(i32), @splat(reach)));
    }
};

pub const Box = struct { min: Coord, max: Coord };

pub fn coords(gpa: std.mem.Allocator, radius: u32, clamp: ?Box) ![]Coord {
    var chunks: std.ArrayList(Coord) = .empty;
    errdefer chunks.deinit(gpa);
    const chunk_span = range(radius);
    var span_min: nz.Vec3(i32) = @splat(chunk_span.min);
    var span_max: nz.Vec3(i32) = @splat(chunk_span.max);
    if (clamp) |box| {
        span_min = @max(span_min, box.min.position);
        span_max = @min(span_max, box.max.position);
    }
    var x = span_min[0];
    while (x <= span_max[0]) : (x += 1) {
        var y = span_min[1];
        while (y <= span_max[1]) : (y += 1) {
            var z = span_min[2];
            while (z <= span_max[2]) : (z += 1) {
                try chunks.append(gpa, .{ .position = .{ x, y, z } });
            }
        }
    }
    return chunks.toOwnedSlice(gpa);
}

pub fn min(chunk: Coord) nz.Vec3(i32) {
    return chunk.position * @as(nz.Vec3(i32), @splat(dim));
}

pub fn max(chunk: Coord) nz.Vec3(i32) {
    return min(chunk) + @as(nz.Vec3(i32), @splat(dim));
}

pub fn range(radius: u32) Range {
    const bound: i32 = @intCast(radius + sdf.noise_amplitude + planet.cell_margin);
    return .{
        .min = @divFloor(-bound, dim),
        .max = @divFloor(bound, dim),
    };
}

test "chunk coordinates cover dim cells" {
    const chunk: Coord = .{ .position = .{ -2, 3, 0 } };
    try std.testing.expectEqual(nz.Vec3(i32){ -64, 96, 0 }, min(chunk));
    try std.testing.expectEqual(nz.Vec3(i32){ -32, 128, 32 }, max(chunk));
}

test "chunk range contains the complete planet density field" {
    try std.testing.expectEqual(Range{ .min = -1, .max = 0 }, range(18));
    try std.testing.expectEqual(Range{ .min = -3, .max = 2 }, range(67));
}

test "chunk coords respect the clamp box" {
    const box: Box = .{ .min = .{ .position = .{ 0, 0, 0 } }, .max = .{ .position = .{ 1, 1, 1 } } };
    const chunks = try coords(std.testing.allocator, 67, box);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len > 0);
    for (chunks) |chunk| {
        try std.testing.expect(@reduce(.And, chunk.position >= box.min.position));
        try std.testing.expect(@reduce(.And, chunk.position <= box.max.position));
    }
}

pub fn Job(comptime kind: planet.PlanetKind) type {
    return struct {
        thread: std.Thread,
        state: *State,

        pub const Result = struct {
            coord: Coord,
            vertices: []planet.Planet(kind).Vertex,
            indices: []u32,
        };

        pub const State = struct {
            gpa: std.mem.Allocator,
            radius: u32,
            coords: []Coord,
            results: std.ArrayList(Result),
            done: std.atomic.Value(bool),
        };

        pub fn start(gpa: std.mem.Allocator, radius: u32, job_coords: []Coord) !@This() {
            errdefer gpa.free(job_coords);
            const state = try gpa.create(State);
            errdefer gpa.destroy(state);
            state.* = .{ .gpa = gpa, .radius = radius, .coords = job_coords, .results = .empty, .done = .init(false) };
            return .{ .thread = try std.Thread.spawn(.{}, generate, .{state}), .state = state };
        }

        pub fn collect(self: @This()) ?std.ArrayList(Result) {
            if (!self.state.done.load(.acquire)) return null;
            self.thread.join();
            const results = self.state.results;
            self.state.gpa.free(self.state.coords);
            self.state.gpa.destroy(self.state);
            return results;
        }

        pub fn join(self: @This()) void {
            self.thread.join();
            for (self.state.results.items) |result| {
                self.state.gpa.free(result.vertices);
                self.state.gpa.free(result.indices);
            }
            self.state.results.deinit(self.state.gpa);
            self.state.gpa.free(self.state.coords);
            self.state.gpa.destroy(self.state);
        }

        fn generate(state: *State) void {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            for (state.coords) |coord| {
                const chunk_mesh = planet.Planet(kind).initChunk(state.gpa, state.radius, coord) catch continue;
                state.results.append(state.gpa, .{ .coord = coord, .vertices = chunk_mesh.vertices, .indices = chunk_mesh.indices }) catch chunk_mesh.deinit(state.gpa);
            }
            state.done.store(true, .release);
        }
    };
}
