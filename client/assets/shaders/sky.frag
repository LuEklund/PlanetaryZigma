
#version 450
layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec3 camera_position;
} scene_data;

layout(location = 0) in vec2 in_ndc;
layout(location = 0) out vec4 out_frag_color;

layout(set = 1, binding = 0) uniform samplerCube sky_cube;

void main() {
  vec4 world = scene_data.inverse_proj_view * vec4(in_ndc, 1, 1);
  world /= world.w;

  vec3 dir = normalize(world.xyz - scene_data.camera_position);

  vec3 base = texture(sky_cube, dir).rgb;

  vec3 L = normalize(scene_data.global_light_direction);
  float d = max(dot(dir, L), 0);
  vec3 glow = vec3(1, 0.8, 0.5) * pow(d, 8.0) * 0.3;
  vec3 disc = vec3(1, 0.95, 0.85) * pow(d, 2000);

  out_frag_color = vec4(base + glow + disc, 1.0);
}
