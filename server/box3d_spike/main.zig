const std = @import("std");
const c = @import("box3d");

// Standalone smoke test / regression test for the vendored Box3D at ../vendor/box3d.
// A pile of overlapping cubes → many simultaneous contacts, so manifolds are
// allocated/freed across multiple block-allocator slots (incl. odd, 4-aligned)
// every step. This is the exact path that aborted before the block_allocator.c
// alignment patch. `zig build run` here should print SPIKE OK.
pub fn main() void {
    var world_def = c.b3DefaultWorldDef();
    world_def.gravity = .{ .x = 0, .y = -10, .z = 0 };
    const world = c.b3CreateWorld(&world_def);
    defer c.b3DestroyWorld(world);

    var ground_def = c.b3DefaultBodyDef();
    ground_def.position = .{ .x = 0, .y = -10, .z = 0 };
    const ground = c.b3CreateBody(world, &ground_def);
    var ground_box = c.b3MakeBoxHull(50, 10, 50);
    var ground_shape_def = c.b3DefaultShapeDef();
    _ = c.b3CreateHullShape(ground, &ground_shape_def, &ground_box.base);

    var cube = c.b3MakeCubeHull(1);
    var shape_def = c.b3DefaultShapeDef();
    shape_def.density = 1;
    shape_def.baseMaterial.friction = 0.3;
    var first_body: c.b3BodyId = undefined;
    for (0..8) |i| {
        var body_def = c.b3DefaultBodyDef();
        body_def.type = c.b3_dynamicBody;
        body_def.position = .{ .x = 0, .y = 2 + @as(f32, @floatFromInt(i)) * 1.5, .z = 0 };
        const body = c.b3CreateBody(world, &body_def);
        _ = c.b3CreateHullShape(body, &shape_def, &cube.base);
        if (i == 0) first_body = body;
    }

    var settled_y: f32 = undefined;
    for (0..200) |_| {
        c.b3World_Step(world, 1.0 / 60.0, 4);
        settled_y = c.b3Body_GetPosition(first_body).y;
    }
    std.debug.print("box3d spike: bottom cube settled at y={d:.3} (expect ~1.0)\n", .{settled_y});
    std.debug.assert(settled_y > 0.8 and settled_y < 1.3);
    std.debug.print("SPIKE OK: 8-cube pile stepped 200x with no UBSan abort in manifold alloc/free\n", .{});
}
