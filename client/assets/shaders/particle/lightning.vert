#version 450
#extension GL_EXT_buffer_reference : require

// One emitter = one bolt. Every particle's position is a pure function of
// (particle_index, age) -- nothing is stored between frames, so there is no compute pass.

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
  vec4 camera_up;
} scene_data;

struct Emitter {
  vec3 origin;
  float spawn_time;
  vec3 target;
  float pad;
};

layout(buffer_reference, std430) readonly buffer EmitterBuffer {
  Emitter emitters[];
};
layout(buffer_reference, std430) readonly buffer JointBuffer {
  mat4 joints[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  EmitterBuffer emitter_buffer;
  JointBuffer joint_buffer;
  uint texture_index;
  uint particle_count;
} push_constant;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out uint out_texture_index;
layout(location = 3) out float out_lifetime;
layout(location = 4) flat out float out_seed;

const vec2 corners[6] = vec2[](
    vec2(-0.5, 0.5), vec2(-0.5, -0.5), vec2(0.5, 0.5),
    vec2(0.5, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5)
  );

const float jitter_nodes = 8.0;

float hash(float n) {
  return fract(sin(n) * 43758.5453123);
}

// Node positions on the smooth arc, offset perpendicular. Particles interpolate BETWEEN
// these, so the bolt stays continuous -- offsetting each particle on its own breaks it.
vec3 nodePosition(float node, vec3 origin, vec3 segment, vec3 direction, vec3 planet_up, float arch_height, float seed) {
  float t = node / jitter_nodes;
  vec3 on_arc = origin + segment * t + planet_up * (arch_height * 4.0 * t * (1.0 - t));
  if (node <= 0.0 || node >= jitter_nodes) return on_arc;

  vec3 raw = normalize(vec3(
        hash(node + seed * 31.0) * 2.0 - 1.0,
        hash(node * 5.1 + seed * 17.0) * 2.0 - 1.0,
        hash(node * 9.7 + seed * 73.0) * 2.0 - 1.0
      ));
  return on_arc + (raw - direction * dot(raw, direction)) * 0.6;
}

void main() {
  uint particle_index = uint(gl_InstanceIndex) % push_constant.particle_count;
  uint emitter_index = uint(gl_InstanceIndex) / push_constant.particle_count;
  Emitter emitter = push_constant.emitter_buffer.emitters[emitter_index];

  float age = scene_data.time - emitter.spawn_time;
  float seed = fract(emitter.spawn_time * 7.13);

  vec3 segment = emitter.target - emitter.origin;
  float length_along = length(segment);
  vec3 direction = segment / max(length_along, 0.0001);
  vec3 planet_up = normalize(emitter.origin);
  float arch_height = length_along * 0.35;

  float t = float(particle_index) / float(push_constant.particle_count - 1);
  float node_position = t * jitter_nodes;
  float node = floor(node_position);
  vec3 particle_position = mix(
      nodePosition(node, emitter.origin, segment, direction, planet_up, arch_height, seed),
      nodePosition(node + 1.0, emitter.origin, segment, direction, planet_up, arch_height, seed),
      fract(node_position)
    );

  float lifetime = 0.22 + hash(seed * 3.0) * 0.08;
  float life = clamp(1.0 - age / lifetime, 0.0, 1.0);
  // overlap neighbours whatever the bolt length, so it never reads as dots
  float spacing = length_along / float(push_constant.particle_count);
  float scale = max(0.55, spacing * 2.0) + hash(float(particle_index) + seed) * 0.15;

  vec2 corner = corners[gl_VertexIndex];
  vec3 forward = normalize(scene_data.camera_position.xyz - particle_position);
  vec3 right = normalize(cross(scene_data.camera_up.xyz, forward));
  vec3 up = cross(forward, right);
  vec3 world_position = particle_position + (right * corner.x + up * corner.y) * scale * life;

  gl_Position = scene_data.proj_view * vec4(world_position, 1.0);
  out_color = vec4(1.0, 1.0, 1.0, 1.0);
  out_uv = vec2(corner.x + 0.5, 0.5 - corner.y);
  out_texture_index = push_constant.texture_index;
  out_lifetime = life;
  out_seed = seed;
}
