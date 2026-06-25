#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

struct Vertex {
  vec3 position;
  float uv_x;
  vec3 normal;
  float uv_y;
  vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertex_buffer;
} push_constant;

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec3 out_normal;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];

  gl_Position = scene_data.proj_view * push_constant.model_matrix * vec4(v.position, 1.0);
  out_frag_color = v.color;
  out_normal = (push_constant.model_matrix * vec4(v.normal, 1)).xyz;
  out_uv = vec2(v.uv_x, v.uv_y);
}
