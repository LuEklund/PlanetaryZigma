const nz = @import("numz");

pub fn projectOnPlane(vector: nz.Vec3(f32), normal: nz.Vec3(f32)) nz.Vec3(f32) {
    return vector - nz.vec.scale(normal, nz.vec.dot(vector, normal));
}

pub fn approach(value: f32, target: f32, step: f32) f32 {
    return if (value < target) @min(target, value + step) else @max(target, value - step);
}

/// Rotation that turns +Y onto `up` (unit length).
pub fn rotationFromUp(up: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
    const dot = @import("std").math.clamp(nz.vec.dot(default_up, up), -1.0, 1.0);
    if (dot >= 0.9999) return .identity;
    const axis = if (dot > -0.9999) nz.vec.normalize(
        nz.vec.cross(default_up, up),
    ) else nz.Vec3(f32){ 1, 0, 0 };
    return .angleAxis(@import("std").math.acos(dot), axis);
}
