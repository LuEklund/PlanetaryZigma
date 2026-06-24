const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

pub fn init(self: *@This()) !void {
    self.* = .{};
}

pub fn deinit(self: *@This()) void {
    _ = self;
}

//NOTE: AI generated! I have no idea about math.

/// Derive each camera's final pose from its persistent state. In follow mode the camera
/// rides the entity's position (plus a boom offset in camera-local space); in free mode
/// camera.transform is treated as independent state and left alone.
pub fn update(self: *@This(), info: *const system.Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.player or !entity.flags.transform) continue;
        const camera = &entity.camera;

        switch (camera.mode) {
            .follow => {
                // Compose final rotation: yaw (tangent-plane) * pitch (around local X).
                const pitch_quat: nz.quat.Hamiltonian(f32) =
                    .angleAxis(camera.pitch, .{ 1, 0, 0 });
                const final_rotation = camera.yaw_rotation.mul(pitch_quat).normalize();

                // Boom offset is expressed in camera-local space, so rotate it into world
                // space before adding to the body position. Zero offset = first-person.
                const boom_world = final_rotation.rotateVec(camera.boom_offset);

                camera.transform.rotation = final_rotation;
                camera.transform.position = entity.transform.position + boom_world;
            },
            .free => {
                // Free camera owns its own transform; nothing to derive.
            },
        }
    }
}
