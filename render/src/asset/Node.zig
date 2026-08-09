const Node = @This();

const nz = @import("shared").numz;

parent: ?usize = null,
mesh_id: ?usize = null,
translation: nz.Vec3(f32) = @splat(0),
scale: nz.Vec3(f32) = @splat(1),
rotation: nz.quat.Hamiltonian(f32) = .identity,
skin_id: ?usize = null,
model_matrix: nz.Mat4x4(f32) = undefined,

pub fn getLocalMatrix(self: *const Node) nz.Mat4x4(f32) {
    return nz.Mat4x4(f32).translate(self.translation)
        .mul(self.rotation.toMat4x4())
        .mul(.scale(self.scale));
}
