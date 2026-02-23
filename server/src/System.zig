const std = @import("std");
// const Physics = @import("Physics.zig");

// physics: *Physics,
number: f32,

pub const InitSystems = *const fn (*@This(), *std.mem.Allocator) callconv(.c) u32;
pub const DeinitSystems = *const fn (*@This(), *std.mem.Allocator) callconv(.c) void;
pub const UpdateSystems = *const fn (*@This(), f32) callconv(.c) void;
// pub const ReloadSystems = *const fn (*@This(), *std.mem.Allocator, bool) callconv(.c) void;

export fn initSystems(self: *@This(), allocator: *std.mem.Allocator) u32 {
    // _ = self;
    _ = allocator;
    self.number = 0;
    // self.physics = Physics.init(allocator) catch |err| return @intFromError(err);
    return 0;
}
export fn deinit(self: *@This(), allocator: *std.mem.Allocator) void {
    _ = self;
    _ = allocator;
    // var query = world.query(&.{ecs.Collider});
    // while (query.next()) |entry| {
    //     var collider = entry.getPtr(ecs.Collider, world).?;
    //     if (collider.shape == .mesh) {
    //         collider.shape.mesh.vertices.deinit(allocator.*);
    //         collider.shape.mesh.indices.deinit(allocator.*);
    //     }
    // }
    //
    // self.physics.deinit(allocator.*);
    // allocator.destroy(self.physics);

    // for (0..self.mesh_shapes.items.len) |i| {
    //     self.mesh_shapes.items[i].indices.deinit(allocator.*);
    //     self.mesh_shapes.items[i].vertices.deinit(allocator.*);
    // }
    // self.mesh_shapes.deinit(allocator.*);
}

export fn update(self: *@This(), delta_time: f32) void {
    self.number = delta_time;
    // _ = delta_time;
    //
}
