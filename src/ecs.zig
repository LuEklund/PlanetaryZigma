const nz = @import("numz");
const std = @import("std");

available_entities: std.Deque(Entity) = .empty,
// transforms: [max_entities]nz.Transform3D(f32) = undefined,
// velocities: [max_entities]nz.Vec3(f32) = undefined,

const max_entities = 4096;

pub const Entity = enum(u32) {
    _,
};

pub fn init(allocator: std.mem.Allocator) !@This() {
    var self: @This() = .{ .available_entities = try .initCapacity(allocator, max_entities) };
    for (0..max_entities) |i| {
        self.available_entities.pushBackAssumeCapacity(@enumFromInt(i));
    }
    return self;
}

pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
    self.available_entities.deinit(allocator);
}

pub fn update(self: @This()) void {
    for (0..max_entities) |i| {
        std.debug.print("id {d}\n", .{@intFromEnum(self.available_entities.at(i))});
    }
}

// pub fn createNewEntity(self: @This()) Entity {
//     self.available_entities.popFront();
// }
