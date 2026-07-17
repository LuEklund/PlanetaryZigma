
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_normal;
layout(location = 3) in vec3 in_world_pos;
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

layout(set = 2, binding = 0) uniform sampler2DShadow shadow_map;
layout(set = 2, binding = 1) uniform cascadeData {
  mat4 light_view_proj[3];
  vec4 splits;
} cascade_data;

float shadowFactor() {
  float dist = distance(scene_data.camera_position.xyz, in_world_pos);
  int cascade;
  if (dist < cascade_data.splits.x) cascade = 0;
  else if (dist < cascade_data.splits.y) cascade = 1;
  else if (dist < cascade_data.splits.z) cascade = 2;
  else return 1.0;

  vec4 light_pos = cascade_data.light_view_proj[cascade] * vec4(in_world_pos, 1.0);
  vec3 ndc = light_pos.xyz; // orthographic: w == 1
  vec2 uv = ndc.xy * 0.5 + 0.5;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0)
    return 1.0;
  float texel = 1.0 / 2048.0;
  uv = clamp(uv, vec2(texel), vec2(1.0 - texel)); // keep hw PCF inside this cascade's tile
  uv.x = (uv.x + float(cascade)) / 3.0;
  return texture(shadow_map, vec3(uv, ndc.z - 0.0015));
}

void main() {
  const float ambient = 0.4;
  float direct = max(dot(normalize(in_normal), normalize(scene_data.global_light_direction)), 0.0);
  float shading = ambient + (1.0 - ambient) * direct * shadowFactor();
  vec4 tex = texture(texSampler, in_uv);
  out_frag_color = vec4((tex.xyz * in_color.xyz * shading) * scene_data.light_color.xyz, tex.a * in_color.a);
}
