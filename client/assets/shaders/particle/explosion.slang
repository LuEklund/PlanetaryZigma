struct SceneData {
  float4x4 proj_view;
  float4x4 inverse_proj_rotation;
  float3 global_light_direction;
  float time;
  float4 camera_position;
  float4 light_color;
  float4 camera_up;
};
[[vk::binding(0, 0)]]
ConstantBuffer<SceneData> scene_data;

struct Emitter {
  float3 origin;
  float spawn_time;
  float3 target;
};

struct Particle {
  float3 position;
  float3 velocity;
  float scale;
  float lifetime;
};

struct PushConstant {
  Emitter *emitter_buffer;
  float elapsed_time;
  uint particle_count;
  uint emitter_count;
  float duration;
};
[[vk::push_constant]]
PushConstant push_constant;

struct VertexOutput {
  float4 position : SV_Position;
  float4 color : COLOR0;
  float2 uv : TEXCOORD0;
};

static const float3 edge_color = float3(1.0, 0.275, 0.047);
static const float3 center_color = float3(1.0, 0.922, 0.188);

static const float2 corners[6] = { float2(-0.5, 0.5),  float2(-0.5, -0.5),
                                   float2(0.5, 0.5),   float2(0.5, 0.5),
                                   float2(-0.5, -0.5), float2(0.5, -0.5) };

static const uint puff_count = 8;
static const float3 puff_offset[puff_count] = {
  float3(0, 0, 0),        float3(-0.15, 0.2, 0.2),  float3(0.2, -0.15, -0.25),
  float3(0.45, 0.1, 0),   float3(-0.35, -0.2, 0.1), float3(0.05, 0.35, -0.15),
  float3(0.3, -0.4, 0.2), float3(-0.45, 0.25, -0.1)
};
static const float3 puff_velocity[puff_count] = {
  float3(0, 0, 0),        float3(-0.5, 0.7, 0.6),  float3(0.7, -0.4, -0.8),
  float3(1.8, 0.4, 0),    float3(-1.2, -0.7, 0.4), float3(0.2, 1.1, -0.5),
  float3(0.9, -1.1, 0.5), float3(-1.0, 0.8, -0.3)
};
static const float puff_scale[puff_count] = { 2.2,  1.95, 1.75, 1.55,
                                              1.35, 1.2,  1.1,  1.0 };
static const float puff_lifetime[puff_count] = { 0.425, 0.475, 0.5,  0.525,
                                                 0.575, 0.625, 0.55, 0.9 };

static const float drag = 0.08;
static const float drag_falloff = 2.5257286;

float hash(float n) { return frac(sin(n) * 43758.5453123); }

Particle spawnParticle(Emitter emitter, uint particle_index) {
  float seed = frac(emitter.spawn_time);
  float3 surface_up = normalize(emitter.origin);
  float3 emitter_origin = emitter.origin + surface_up * 1.15;

  Particle particle;
  if (particle_index < puff_count) {
    float3 offset = puff_offset[particle_index];
    particle.position =
        emitter_origin + (offset - surface_up * dot(offset, surface_up));
    particle.velocity = puff_velocity[particle_index] + surface_up * 1.4;
    particle.scale = puff_scale[particle_index];
    particle.lifetime = puff_lifetime[particle_index] * push_constant.duration;
  } else {
    float spark = float(particle_index - puff_count);
    float burst = (particle_index - puff_count) < 16 ? 0.0 : 1.0;
    float r0 = hash(spark + seed);
    float r1 = hash(r0);
    float r2 = hash(r1);

    float z = r0 * 2.0 - 1.0;
    float theta = r1 * 6.2831853;
    float2 ring = sqrt(max(0.0, 1.0 - z * z)) * float2(cos(theta), sin(theta));
    float3 direction = float3(ring.x, z, ring.y);
    float outward = dot(direction, surface_up);
    if (outward < 0.2)
      direction = normalize(direction + surface_up * (0.35 - outward));

    particle.lifetime =
        (0.525 + r2 * 0.35 + burst * 0.075) * push_constant.duration;
    particle.velocity = direction * (12.0 + r1 * 7.0 + burst * 4.0);
    particle.scale = (0.3 + r0 * 0.22) * (1.0 - burst * 0.15);
    particle.position =
        emitter_origin + direction * (burst * 0.35 + spark * 0.01);
  }
  return particle;
}

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID,
                    uint instance_index: SV_InstanceID) {
  uint particle_index = instance_index % push_constant.particle_count;
  uint emitter_index = instance_index / push_constant.particle_count;
  Emitter emitter = push_constant.emitter_buffer[emitter_index];
  Particle particle = spawnParticle(emitter, particle_index);

  float age = push_constant.elapsed_time - emitter.spawn_time;
  float3 position = particle.position +
                    particle.velocity * (1.0 - pow(drag, age)) / drag_falloff;
  float life = clamp(1.0 - age / particle.lifetime, 0.0, 1.0);

  float2 corner = corners[vertex_index];
  float3 forward = normalize(scene_data.camera_position.xyz - position);
  float3 right = normalize(cross(scene_data.camera_up.xyz, forward));
  float3 up = cross(forward, right);
  float3 world_position =
      position + (right * corner.x + up * corner.y) * particle.scale * life;

  VertexOutput output;
  output.position = mul(scene_data.proj_view, float4(world_position, 1.0));
  output.color = float4(1.0, 1.0, 1.0, 1.0);
  output.uv = float2(corner.x + 0.5, 0.5 - corner.y);
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
  float core = clamp(1.0 - length(input.uv * 2.0 - 1.0), 0.0, 1.0);
  return float4(lerp(edge_color, center_color, sqrt(core)), core * core) *
         input.color;
}
