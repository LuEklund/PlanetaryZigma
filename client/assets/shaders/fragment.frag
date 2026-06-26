
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_normal;
layout(location = 0) out vec4 out_frag_color;

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

void main() {
  float diff = max(dot(normalize(in_normal), normalize(scene_data.global_light_direction)), 0.4);
  out_frag_color = vec4((texture(texSampler, in_uv).xyz * diff) * scene_data.light_color.xyz, 1);
  // out_frag_color = in_color;
}
