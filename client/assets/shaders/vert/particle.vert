#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  mat4 inverse_proj_view;
  vec3 global_light_direction;
  float time;
  vec4 camera_position;
  vec4 light_color;
  vec4 camera_up;
} scene_data;

struct Particle {
  vec3 position;
  float scale;
  uint texture_index;
  float alpha;
  float lifetime_fraction;
  float seed;
};

layout(buffer_reference, std430) readonly buffer ParticleBuffer {
  Particle particles[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  ParticleBuffer particle_buffer;
} push_constant;

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out uint out_texture_index;
layout(location = 3) out float out_lifetime;
layout(location = 4) flat out float out_seed;

const vec2 corners[6] = vec2[](
  vec2(-0.5, 0.5), vec2(-0.5, -0.5), vec2(0.5, 0.5),
  vec2(0.5, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5)
);

void main() {
  Particle particle = push_constant.particle_buffer.particles[gl_InstanceIndex];
  vec2 corner = corners[gl_VertexIndex];
  vec3 forward = normalize(scene_data.camera_position.xyz - particle.position);
  vec3 right = normalize(cross(scene_data.camera_up.xyz, forward));
  vec3 up = cross(forward, right);
  float scale = particle.scale * particle.lifetime_fraction;
  vec3 world_position = particle.position + (right * corner.x + up * corner.y) * scale;
  gl_Position = scene_data.proj_view * vec4(world_position, 1.0);
  out_frag_color = vec4(1.0, 1.0, 1.0, particle.alpha);
  out_uv = vec2(corner.x + 0.5, 0.5 - corner.y);
  out_texture_index = particle.texture_index;
  out_lifetime = particle.lifetime_fraction;
  out_seed = particle.seed;
}
