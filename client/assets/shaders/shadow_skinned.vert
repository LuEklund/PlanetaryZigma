#version 450
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec3 position;
  float uv_x;
  vec3 normal;
  float uv_y;
  vec4 color;
  ivec4 joint_indices;
  vec4 joint_weights;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(buffer_reference, std430) readonly buffer JointMatrices {
  mat4 matrices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertex_buffer;
  JointMatrices joint_matrices;
} push_constant;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];

  if (v.joint_weights.x != -1) {
    mat4 skin_mat =
      v.joint_weights.x * push_constant.joint_matrices.matrices[int(v.joint_indices.x)] +
        v.joint_weights.y * push_constant.joint_matrices.matrices[int(v.joint_indices.y)] +
        v.joint_weights.z * push_constant.joint_matrices.matrices[int(v.joint_indices.z)] +
        v.joint_weights.w * push_constant.joint_matrices.matrices[int(v.joint_indices.w)];
    gl_Position = push_constant.model_matrix * skin_mat * vec4(v.position, 1.0);
  } else {
    gl_Position = push_constant.model_matrix * vec4(v.position, 1.0);
  }
}
