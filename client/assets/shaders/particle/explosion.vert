#version 450
#extension GL_EXT_buffer_reference : require

// One emitter = one explosion. Every particle's position is a pure function of
// (particle_index, age) -- nothing is stored between frames, so there is no compute pass.

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_rotation;
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

layout(buffer_reference, std430) readonly buffer EmitterBuffer { Emitter emitters[]; };
layout(buffer_reference, std430) readonly buffer JointBuffer { mat4 joints[]; };

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

const uint puff_count = 8;
const vec3 puff_offset[puff_count] = vec3[](
  vec3(0, 0, 0), vec3(-0.15, 0.2, 0.2), vec3(0.2, -0.15, -0.25), vec3(0.45, 0.1, 0),
  vec3(-0.35, -0.2, 0.1), vec3(0.05, 0.35, -0.15), vec3(0.3, -0.4, 0.2), vec3(-0.45, 0.25, -0.1)
);
const vec3 puff_velocity[puff_count] = vec3[](
  vec3(0, 0, 0), vec3(-0.5, 0.7, 0.6), vec3(0.7, -0.4, -0.8), vec3(1.8, 0.4, 0),
  vec3(-1.2, -0.7, 0.4), vec3(0.2, 1.1, -0.5), vec3(0.9, -1.1, 0.5), vec3(-1.0, 0.8, -0.3)
);
const float puff_scale[puff_count] = float[](2.2, 1.95, 1.75, 1.55, 1.35, 1.2, 1.1, 1.0);
const float puff_lifetime[puff_count] = float[](0.34, 0.38, 0.4, 0.42, 0.46, 0.5, 0.44, 0.48);

// matches the CPU drag that used to live in Particle.update: v *= 0.08^dt
const float drag = 0.08;
float dragTravel(float age) { return (1.0 - pow(drag, age)) / 2.5257286; }

float hash(float n) { return fract(sin(n) * 43758.5453123); }

void main() {
  uint particle_index = uint(gl_InstanceIndex) % push_constant.particle_count;
  uint emitter_index = uint(gl_InstanceIndex) / push_constant.particle_count;
  Emitter emitter = push_constant.emitter_buffer.emitters[emitter_index];

  float age = scene_data.time - emitter.spawn_time;
  float seed = fract(emitter.spawn_time * 7.13);
  vec3 surface_up = normalize(emitter.origin);

  vec3 start;
  vec3 velocity;
  float scale;
  float lifetime;

  if (particle_index < puff_count) {
    vec3 offset = puff_offset[particle_index];
    start = emitter.origin + (offset - surface_up * dot(offset, surface_up));
    velocity = puff_velocity[particle_index] + surface_up * 1.4;
    scale = puff_scale[particle_index];
    lifetime = puff_lifetime[particle_index];
  } else {
    float spark = float(particle_index - puff_count);
    float burst = (particle_index - puff_count) < 16 ? 0.0 : 1.0;
    float r0 = hash(spark + seed * 91.0);
    float r1 = hash(spark * 3.7 + seed * 13.0);
    float r2 = hash(spark * 11.3 + seed * 57.0);

    float z = r0 * 2.0 - 1.0;
    float theta = r1 * 6.2831853;
    vec3 direction = vec3(sqrt(max(0.0, 1.0 - z * z)) * vec2(cos(theta), sin(theta)), z).xzy;
    float outward = dot(direction, surface_up);
    if (outward < 0.2) direction = normalize(direction + surface_up * (0.35 - outward));

    lifetime = 0.42 + r2 * 0.28 + burst * 0.06;
    velocity = direction * (12.0 + r1 * 7.0 + burst * 4.0);
    scale = (0.3 + r0 * 0.22) * (1.0 - burst * 0.15);
    start = emitter.origin + direction * (burst * 0.35 + spark * 0.01);
  }

  float life = clamp(1.0 - age / lifetime, 0.0, 1.0);
  vec3 particle_position = start + velocity * dragTravel(age);

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
