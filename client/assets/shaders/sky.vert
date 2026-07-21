// vertex.glsl
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

layout(location = 0) out vec2 out_ndc;

void main() {
  vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
  out_ndc = p * 2 - 1.0;
  gl_Position = vec4(out_ndc, 1.0, 1.0);
}
