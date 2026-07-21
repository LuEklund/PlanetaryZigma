#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_rotation;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
} scene_data;

struct Vertex {
  vec4 position;
  vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertex_buffer;
} push_constant;

layout(location = 0) out vec4 out_color;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];
  gl_Position = scene_data.proj_view * push_constant.model_matrix * vec4(v.position.xyz, 1.0);
  out_color = v.color;
}
