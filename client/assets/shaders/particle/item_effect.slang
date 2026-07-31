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
  float2 uv : TEXCOORD0;
  nointerpolation float strand_seed : TEXCOORD1;
  nointerpolation float strand_alpha : TEXCOORD2;
};

struct Strand {
  float3 origin;
  float3 side;
  float3 forward;
  float3 up;
  float seed;
  float height;
  float radius;
  float turn;
  float spin;
};

static const float2 corners[6] = { float2(-0.5, 0.5),  float2(-0.5, -0.5),
                                   float2(0.5, 0.5),   float2(0.5, 0.5),
                                   float2(-0.5, -0.5), float2(0.5, -0.5) };

static const float4 ramp_steps = float4(0.26, 0.42, 0.58, 0.74);
static const float3 ramp_colors[5] = {
  float3(0.03, 0.14, 0.07), float3(0.07, 0.32, 0.15), float3(0.16, 0.58, 0.26),
  float3(0.38, 0.82, 0.38), float3(0.74, 1.0, 0.66)
};

static const float column_height = 1.1;
static const float column_radius = 0.8;
static const float turns = 1.15;
static const float spin_speed = 0.55;
static const float ribbon_width = 0.13;
static const float scroll_speed = 0.4;
static const float base_alpha = 0.8;
static const uint strand_count = 7; // must match ParticleInfo.strands for .item_effect

float hash(float n) { return frac(sin(n) * 43758.5453123); }

float hash2(float2 p) {
  return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float valueNoise(float2 p) {
  float2 cell = floor(p);
  float2 fraction = frac(p);
  float2 blend = fraction * fraction * (3.0 - 2.0 * fraction);
  return lerp(lerp(hash2(cell), hash2(cell + float2(1.0, 0.0)), blend.x),
              lerp(hash2(cell + float2(0.0, 1.0)),
                   hash2(cell + float2(1.0, 1.0)), blend.x),
              blend.y);
}

float fbm(float2 p) {
  return valueNoise(p) * 0.6 + valueNoise(p * 2.3) * 0.3 +
         valueNoise(p * 4.7) * 0.1;
}

float3 colorRamp(float intensity) {
  float3 color = ramp_colors[0];
  color = intensity < ramp_steps.x ? color : ramp_colors[1];
  color = intensity < ramp_steps.y ? color : ramp_colors[2];
  color = intensity < ramp_steps.z ? color : ramp_colors[3];
  return intensity < ramp_steps.w ? color : ramp_colors[4];
}

float3 strandPoint(Strand strand, float t) {
  float angle = strand.seed * 6.2831853 + t * strand.turn * 6.2831853 +
                scene_data.time * strand.spin;
  float radius = strand.radius * sin(t * 2.7 + 0.25);
  float sway =
      sin(scene_data.time * 1.6 + strand.seed * 6.2831853 + t * 4.5) * 0.05 * t;
  return strand.origin + strand.up * (t * strand.height) +
         (strand.side * cos(angle) + strand.forward * sin(angle)) *
             (radius + sway);
}

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID,
                        uint instance_index: SV_InstanceID) {
  uint segment_count = push_constant.particle_count / strand_count - 1;
  uint strand_instances = segment_count * strand_count;
  uint emitter_index = instance_index / strand_instances;
  uint strand_index = (instance_index % strand_instances) / segment_count;
  uint segment_index = instance_index % segment_count;

  Emitter emitter = push_constant.emitter_buffer[emitter_index];
  float seed = hash(frac(emitter.spawn_time) + float(strand_index));
  float height_random = hash(seed);
  float radius_random = hash(height_random);
  float turn_random = hash(radius_random);
  float direction_random = hash(turn_random);
  float speed_random = hash(direction_random);
  float jitter_angle_random = hash(speed_random);
  float jitter_radius_random = hash(jitter_angle_random);
  float lift_random = hash(jitter_radius_random);
  float width_random = hash(lift_random);
  float alpha_random = hash(width_random);

  Strand strand;
  strand.up = normalize(emitter.origin);
  strand.side =
      normalize(cross(strand.up, float3(0.0, 0.0, 1.0) + strand.up * 0.5));
  strand.forward = cross(strand.up, strand.side);
  strand.seed = seed;
  strand.height = column_height * (0.7 + height_random * 0.7);
  strand.radius = column_radius * (0.6 + radius_random * 0.8);
  strand.turn = turns * (0.6 + turn_random * 0.9);
  strand.spin = spin_speed * (direction_random < 0.5 ? -1.0 : 1.0) *
                (0.6 + speed_random * 0.8);

  float jitter_angle = jitter_angle_random * 6.2831853;
  float jitter_radius = jitter_radius_random * 0.13;
  strand.origin =
      emitter.origin +
      (strand.side * cos(jitter_angle) + strand.forward * sin(jitter_angle)) *
          jitter_radius +
      strand.up * (lift_random * 0.1);

  float t0 = float(segment_index) / float(segment_count);
  float t1 = float(segment_index + 1) / float(segment_count);
  float3 start = strandPoint(strand, t0);
  float3 end = strandPoint(strand, t1);

  float2 corner = corners[vertex_index];
  float along = corner.x + 0.5;
  float t = lerp(t0, t1, along);
  float3 center = lerp(start, end, along);
  float3 view = normalize(scene_data.camera_position.xyz - center);
  float3 tangent =
      strandPoint(strand, t + 0.01) - strandPoint(strand, t - 0.01);
  float3 across = cross(tangent, view);
  float width = ribbon_width * sin(t * 3.1415926) * 1.7 *
                (0.65 + width_random * 0.8);

  VertexOutput output;
  output.position = mul(
      scene_data.proj_view,
      float4(center + across / max(length(across), 0.0001) * corner.y * width,
             1.0));
  output.uv = float2(corner.y + 0.5, t);
  output.strand_seed = seed;
  output.strand_alpha = 0.4 + alpha_random * 0.6;
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
  float2 base_uv =
      float2(input.uv.x * 1.4,
             input.uv.y * 2.6 - scene_data.time * scroll_speed *
                                    (0.7 + input.strand_seed * 0.6)) +
      input.strand_seed * 17.0;

  float2 pan = float2(scene_data.time * 0.05, scene_data.time * -0.09);
  float2 distortion =
      float2(fbm(base_uv * 1.6 + pan), fbm(base_uv * 1.6 + pan.yx + 17.3)) *
          2.0 -
      1.0;

  float noise_value = fbm(base_uv * 2.2 + distortion * 0.3);
  float across_falloff = 1.0 - abs(input.uv.x * 2.0 - 1.0);
  float density = noise_value * across_falloff;

  float threshold = 0.62 * input.uv.y;
  float alpha = smoothstep(threshold, threshold + 0.12, density);
  if (alpha <= 0.0)
    discard;

  return float4(colorRamp(density), alpha * base_alpha * input.strand_alpha);
}
