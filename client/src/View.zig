const shared = @import("shared");
const nz = shared.numz;

pub const Frame = struct {
    delta_time: f32,
    local_entity: shared.entity.Id,
    camera_pitch: f32,
    camera_yaw_rotation: nz.Quat(f32),
};

pub const Entity = struct {
    id: shared.entity.Id,
    kind: shared.entity.Kind,
    transform: nz.Transform3D(f32),
    velocity: nz.Vec3(f32),
    is_dying: bool,
    stun_time: f32,
    state_override: ?shared.entity.State,
};
