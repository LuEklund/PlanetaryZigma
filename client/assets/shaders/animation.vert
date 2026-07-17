// vertex.glsl
#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

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

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec3 out_normal;
layout(location = 3) out vec3 out_world_pos;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];
  float time = scene_data.time;
  float x = v.position.x;
  float y = v.position.y;
  float z = v.position.z;

  if (v.joint_weights.x != -1) {
    mat4 skin_mat =
      v.joint_weights.x * push_constant.joint_matrices.matrices[int(v.joint_indices.x)] +
        v.joint_weights.y * push_constant.joint_matrices.matrices[int(v.joint_indices.y)] +
        v.joint_weights.z * push_constant.joint_matrices.matrices[int(v.joint_indices.z)] +
        v.joint_weights.w * push_constant.joint_matrices.matrices[int(v.joint_indices.w)];

    vec4 world_pos = push_constant.model_matrix * skin_mat * vec4(x, y, z, 1.0);
    out_world_pos = world_pos.xyz;
    gl_Position = scene_data.proj_view * world_pos;
    out_normal = (push_constant.model_matrix * skin_mat * vec4(v.normal, 0)).xyz;
  }
  else {
    out_normal = (push_constant.model_matrix * vec4(v.normal, 0)).xyz;
    vec4 world_pos = push_constant.model_matrix * vec4(x, y, z, 1.0);
    out_world_pos = world_pos.xyz;
    gl_Position = scene_data.proj_view * world_pos;
  }

  // gl_Position = scene_data.proj_view * vec4(x, y, z, 1.0);

  // vec3 uv = vec3(v.uv_x, v.uv_y, v.uv_x);
  // vec3 col = 0.5 + 0.5 * cos(scene_data.time + v.uv_x + vec3(0, 2, 4));
  // out_frag_color = vec4(col, 1);
  // vec3 col = vec3(1, 0, 0);

  // float red = (y > 0) ? 1 : 0;
  // vec3 col = vec3(red, 0, 0);

  // out_frag_color = v.joint_indices.x == -1 ? vec4(v.color) : vec4(col, 1);
  // out_frag_color = vec4(col, 1);
  out_frag_color = v.color;
  out_uv = vec2(v.uv_x, v.uv_y);
}
