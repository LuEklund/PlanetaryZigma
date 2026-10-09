const nz = @import("numz");

pub fn projectOnPlane(vector: nz.Vec3(f32), normal: nz.Vec3(f32)) nz.Vec3(f32) {
    return vector - nz.vec.scale(normal, nz.vec.dot(vector, normal));
}

pub fn approach(value: f32, target: f32, step: f32) f32 {
    return if (value < target) @min(target, value + step) else @max(target, value - step);
}
