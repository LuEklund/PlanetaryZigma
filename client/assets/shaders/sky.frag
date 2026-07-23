
#version 450
layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_rotation;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
} scene_data;

layout(location = 0) in vec2 in_ndc;
layout(location = 0) out vec4 out_frag_color;

layout(set = 1, binding = 0) uniform samplerCube sky_cube;

void main() {
  vec4 ray = scene_data.inverse_proj_rotation * vec4(in_ndc, 1, 1);
  vec3 direction = normalize(ray.xyz / ray.w);

  vec3 base_color = texture(sky_cube, direction).rgb;

  vec3 normaized_light_directon = normalize(scene_data.global_light_direction);
  float dotproduct_sun = max(dot(direction, normaized_light_directon), 0);
  vec3 glow = vec3(1, 0.8, 0.5) * pow(dotproduct_sun, 8.0) * 0.3;
  vec3 disc = vec3(1, 0.95, 0.85) * pow(dotproduct_sun, 2000);

  out_frag_color = vec4((base_color + glow + disc) * scene_data.light_color.xyz, 1.0);
}
