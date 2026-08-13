const std = @import("std");
const nz = @import("numz");
const Resources = @import("Resources.zig");

// Half-diagonal of the largest caster. Chunks are 32 units, so a centre-point cascade test
// needs at least that much slack or they pop out of the shadow pass at cascade edges.
const shadow_caster_radius: f32 = 32;

pub fn getViewMatrix(transform: *const nz.Transform3D(f32)) nz.Mat4x4(f32) {
    const inv_rotation = transform.rotation.conjugate().toMat4x4();
    const inv_translation = nz.Mat4x4(f32).translate(-transform.position);

    return inv_rotation.mul(inv_translation);
}

pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    const f = 1.0 / std.math.tan(fovy_rad / 2.0);
    return .new(.{
        f / aspect, 0, 0, 0,
        0, -f, 0,                           0, // flip Y for Vulkan
        0, 0,  far / (near - far),          -1,
        0, 0,  (far * near) / (near - far), 0,
    });
}

pub fn cascadeViewProj(camera: nz.Transform3D(f32), fov_rad: f32, aspect: f32, slice_near: f32, slice_far: f32, light_dir: nz.Vec3(f32)) nz.Mat4x4(f32) {
    const forward = camera.rotation.rotateVec(.{ 0, 0, -1 });
    const right = camera.rotation.rotateVec(.{ 1, 0, 0 });
    const up = camera.rotation.rotateVec(.{ 0, 1, 0 });
    const tan_half_fov = @tan(fov_rad * 0.5);

    var corners: [8]nz.Vec3(f32) = undefined;
    for ([2]f32{ slice_near, slice_far }, 0..) |plane_distance, plane| {
        const half_height = plane_distance * tan_half_fov;
        const half_width = half_height * aspect;
        const plane_center = camera.position + nz.vec.scale(forward, plane_distance);
        for (0..4) |corner| {
            const sign_x: f32 = if (corner & 1 == 0) -1 else 1;
            const sign_y: f32 = if (corner & 2 == 0) -1 else 1;
            corners[plane * 4 + corner] = plane_center +
                nz.vec.scale(right, sign_x * half_width) +
                nz.vec.scale(up, sign_y * half_height);
        }
    }

    var center: nz.Vec3(f32) = .{ 0, 0, 0 };
    for (corners) |corner| center += corner;
    center = nz.vec.scale(center, 1.0 / 8.0);
    var radius: f32 = 0;
    for (corners) |corner| radius = @max(radius, nz.vec.length(corner - center));

    const normalized_light = nz.vec.normalize(light_dir);
    const up_reference: nz.Vec3(f32) = if (@abs(normalized_light[1]) > 0.99) .{ 0, 0, 1 } else .{ 0, 1, 0 };
    const light_view = nz.Mat4x4(f32).lookAt(.{ 0, 0, 0 }, -normalized_light, up_reference);

    const center_light = light_view.mulVec4(.{ center[0], center[1], center[2], 1 });
    const texel_size = radius * 2.0 / @as(f32, @floatFromInt(Resources.shadow_map_size));
    const snapped_x = @floor(center_light[0] / texel_size) * texel_size;
    const snapped_y = @floor(center_light[1] / texel_size) * texel_size;

    const caster_pad: f32 = 80; // room behind the slice for off-screen casters
    const proj = shadowOrtho(
        snapped_x - radius,
        snapped_x + radius,
        snapped_y - radius,
        snapped_y + radius,
        -(center_light[2] + radius + caster_pad),
        -(center_light[2] - radius),
    );
    return proj.mul(light_view);
}

pub fn cascadeContains(cascade_vp: *const nz.Mat4x4(f32), position: nz.Vec3(f32)) bool {
    const clip = cascade_vp.mulVec4(.{ position[0], position[1], position[2], 1 });
    const margin_x = shadow_caster_radius * @abs(cascade_vp.d[0]);
    const margin_y = shadow_caster_radius * @abs(cascade_vp.d[5]);
    const margin_z = shadow_caster_radius * @abs(cascade_vp.d[10]);
    return @abs(clip[0]) <= 1 + margin_x and
        @abs(clip[1]) <= 1 + margin_y and
        clip[2] >= -margin_z and clip[2] <= 1 + margin_z;
}

fn shadowOrtho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    return .new(.{
        2.0 / (right - left),             0,                               0,                   0,
        0,                                -2.0 / (top - bottom),           0,                   0,
        0,                                0,                               1.0 / (near - far),  0,
        -(right + left) / (right - left), (top + bottom) / (top - bottom), near / (near - far), 1,
    });
}
