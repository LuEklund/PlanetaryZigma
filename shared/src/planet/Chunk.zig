const std = @import("std");
const nz = @import("numz");
const tracy = @import("ztracy");
const sdf = @import("sdf.zig");
const planet = @import("root.zig");

pub const dim: i32 = 32;

pub const Range = struct { min: i32, max: i32 };

pub const Box = struct { min: nz.Vec3(i32), max: nz.Vec3(i32) };

pub const Kind = enum { empty, solid, surface };

const classify_margin: f32 = sdf.noise_amplitude + planet.cell_margin + 1;

pub fn classify(radius: u32, chunk: nz.Vec3(i32)) Kind {
    const box_min: nz.Vec3(f32) = @floatFromInt(min(chunk));
    const box_max: nz.Vec3(f32) = @floatFromInt(max(chunk));
    const nearest = @max(box_min, @min(box_max, @as(nz.Vec3(f32), @splat(0))));
    const farthest = @max(@abs(box_min), @abs(box_max));
    const radius_float: f32 = @floatFromInt(@max(radius, planet.min_radius));
    if (nz.vec.length(nearest) > radius_float + classify_margin) return .empty;
    if (nz.vec.length(farthest) < radius_float - classify_margin) return .solid;
    return .surface;
}

pub fn surfaceCoords(gpa: std.mem.Allocator, radius: u32, clamp: ?Box) ![]nz.Vec3(i32) {
    var chunks: std.ArrayList(nz.Vec3(i32)) = .empty;
    errdefer chunks.deinit(gpa);
    const chunk_span = range(radius);
    var span_min: nz.Vec3(i32) = @splat(chunk_span.min);
    var span_max: nz.Vec3(i32) = @splat(chunk_span.max);
    if (clamp) |box| {
        span_min = @max(span_min, box.min);
        span_max = @min(span_max, box.max);
    }
    var x = span_min[0];
    while (x <= span_max[0]) : (x += 1) {
        var y = span_min[1];
        while (y <= span_max[1]) : (y += 1) {
            var z = span_min[2];
            while (z <= span_max[2]) : (z += 1) {
                const chunk: nz.Vec3(i32) = .{ x, y, z };
                if (classify(radius, chunk) == .surface) try chunks.append(gpa, chunk);
            }
        }
    }
    return chunks.toOwnedSlice(gpa);
}

pub fn fromPosition(position: nz.Vec3(f32)) nz.Vec3(i32) {
    return @intFromFloat(@floor(position / @as(nz.Vec3(f32), @splat(@floatFromInt(dim)))));
}

pub fn min(chunk: nz.Vec3(i32)) nz.Vec3(i32) {
    return chunk * @as(nz.Vec3(i32), @splat(dim));
}

pub fn max(chunk: nz.Vec3(i32)) nz.Vec3(i32) {
    return min(chunk) + @as(nz.Vec3(i32), @splat(dim));
}

pub fn range(radius: u32) Range {
    const bound: i32 = @intCast(@max(radius, planet.min_radius) + sdf.noise_amplitude + planet.cell_margin);
    return .{
        .min = @divFloor(-bound, dim),
        .max = @divFloor(bound, dim),
    };
}

test "chunk coordinates cover dim cells" {
    const chunk: nz.Vec3(i32) = .{ -2, 3, 0 };
    try std.testing.expectEqual(nz.Vec3(i32){ -64, 96, 0 }, min(chunk));
    try std.testing.expectEqual(nz.Vec3(i32){ -32, 128, 32 }, max(chunk));
}

test "chunk range contains the complete planet density field" {
    try std.testing.expectEqual(Range{ .min = -1, .max = 0 }, range(18));
    try std.testing.expectEqual(Range{ .min = -3, .max = 2 }, range(67));
}

test "surface chunks respect the clamp box" {
    const box: Box = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    const chunks = try surfaceCoords(std.testing.allocator, 67, box);
    defer std.testing.allocator.free(chunks);
    try std.testing.expect(chunks.len > 0);
    for (chunks) |chunk| {
        try std.testing.expect(@reduce(.And, chunk >= box.min));
        try std.testing.expect(@reduce(.And, chunk <= box.max));
    }
}

pub fn Job(comptime kind: planet.PlanetKind) type {
    return struct {
        thread: std.Thread,
        state: *State,

        pub const Result = struct {
            coord: nz.Vec3(i32),
            vertices: []planet.Planet(kind).Vertex,
            indices: []u32,
        };

        pub const State = struct {
            gpa: std.mem.Allocator,
            radius: u32,
            coords: []nz.Vec3(i32),
            results: std.ArrayList(Result),
            done: std.atomic.Value(bool),
        };

        pub fn start(gpa: std.mem.Allocator, radius: u32, coords: []nz.Vec3(i32)) !@This() {
            errdefer gpa.free(coords);
            const state = try gpa.create(State);
            errdefer gpa.destroy(state);
            state.* = .{ .gpa = gpa, .radius = radius, .coords = coords, .results = .empty, .done = .init(false) };
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
