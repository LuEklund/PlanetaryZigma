const nz = @import("numz");
const Vec3 = nz.Vec3(f32);

pub const muzzle_speed: f32 = 100;
pub const gravity_acceleration: f32 = 100;
pub const lifetime: f32 = 5;

pub fn step(position: *Vec3, velocity: *Vec3, dt: f32) void {
    const up = nz.vec.normalize(position.*);
    velocity.* += nz.vec.scale(-up, gravity_acceleration * dt);
    position.* += nz.vec.scale(velocity.*, dt);
}
