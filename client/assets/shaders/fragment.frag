
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

  float texel_world = 2.0 / (cascade_data.light_view_proj[cascade][0][0] * 2048.0);
  vec3 sample_pos = in_world_pos + normalize(in_normal) * texel_world * 1.5;

  vec4 light_pos = cascade_data.light_view_proj[cascade] * vec4(sample_pos, 1.0);
  vec3 ndc = light_pos.xyz; // orthographic: w == 1
  vec2 uv = ndc.xy * 0.5 + 0.5;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0)
    return 1.0;

  const vec2 poisson[12] = vec2[](
    vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696, 0.457),
    vec2(-0.203, 0.621), vec2(0.962, -0.195), vec2(0.473, -0.480),
    vec2(0.519, 0.767), vec2(0.185, -0.893), vec2(0.507, 0.064),
    vec2(0.896, 0.412), vec2(-0.322, -0.933), vec2(-0.792, -0.598));
  float texel = 1.0 / 2048.0;
  float pcf_radius = 2.0 * texel;
  float depth_ref = ndc.z - 0.0005;
  float sum = 0.0;
  for (int i = 0; i < 12; i++) {
    vec2 tap = clamp(uv + poisson[i] * pcf_radius, vec2(texel), vec2(1.0 - texel));
    tap.x = (tap.x + float(cascade)) / 3.0;
    sum += texture(shadow_map, vec3(tap, depth_ref));
  }
  return sum / 12.0;
}

void main() {
  const float ambient = 0.4;
  float direct = max(dot(normalize(in_normal), normalize(scene_data.global_light_direction)), 0.0);
  float shading = ambient + (1.0 - ambient) * direct * shadowFactor();
  vec4 tex = texture(texSampler, in_uv);
  out_frag_color = vec4((tex.xyz * in_color.xyz * shading) * scene_data.light_color.xyz, tex.a * in_color.a);
}
