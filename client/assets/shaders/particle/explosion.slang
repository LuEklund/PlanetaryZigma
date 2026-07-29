struct SceneData {
    float4x4 proj_view;
    float4x4 inverse_proj_rotation;
    float3 global_light_direction;
    float time;
    float4 camera_position;
    float4 light_color;
    float4 camera_up;
};
[[vk::binding(0, 0)]] ConstantBuffer<SceneData> scene_data;

[[vk::binding(0, 1)]] Sampler2D textures[256];

struct Emitter {
    float3 origin;
    float spawn_time;
    float3 target;
    uint slot;
};

struct PushConstant {
    float4x4 model_matrix;
    Emitter *emitter_buffer;
    float4x4 *joint_buffer;
    uint texture_index;
    uint particle_count;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
    nointerpolation uint texture_index : TEXCOORD1;
};

static const float2 corners[6] = {
    float2(-0.5, 0.5), float2(-0.5, -0.5), float2(0.5, 0.5),
    float2(0.5, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5)
};

static const uint puff_count = 8;
static const float3 puff_offset[puff_count] = {
    float3(0, 0, 0), float3(-0.15, 0.2, 0.2), float3(0.2, -0.15, -0.25), float3(0.45, 0.1, 0),
    float3(-0.35, -0.2, 0.1), float3(0.05, 0.35, -0.15), float3(0.3, -0.4, 0.2), float3(-0.45, 0.25, -0.1)
};
static const float3 puff_velocity[puff_count] = {
    float3(0, 0, 0), float3(-0.5, 0.7, 0.6), float3(0.7, -0.4, -0.8), float3(1.8, 0.4, 0),
    float3(-1.2, -0.7, 0.4), float3(0.2, 1.1, -0.5), float3(0.9, -1.1, 0.5), float3(-1.0, 0.8, -0.3)
};
static const float puff_scale[puff_count] = { 2.2, 1.95, 1.75, 1.55, 1.35, 1.2, 1.1, 1.0 };
static const float puff_lifetime[puff_count] = { 0.34, 0.38, 0.4, 0.42, 0.46, 0.5, 0.44, 0.48 };

// matches the CPU drag that used to live in Particle.update: v *= 0.08^dt
static const float drag = 0.08;
float dragTravel(float age) { return (1.0 - pow(drag, age)) / 2.5257286; }

float hash(float n) { return frac(sin(n) * 43758.5453123); }

[shader("vertex")]
VertexOutput vertMain(uint vertex_index: SV_VertexID, uint instance_index: SV_InstanceID) {
    uint particle_index = instance_index % push_constant.particle_count;
    uint emitter_index = instance_index / push_constant.particle_count;
    Emitter emitter = push_constant.emitter_buffer[emitter_index];

    float age = scene_data.time - emitter.spawn_time;
    float seed = frac(emitter.spawn_time * 7.13);
    float3 surface_up = normalize(emitter.origin);
    // lift the blast off the impact point -- visual authoring, belongs here not on the CPU
    float3 emitter_origin = emitter.origin + surface_up * 1.15;

    float3 start;
    float3 velocity;
    float scale;
    float lifetime;

    if (particle_index < puff_count) {
        float3 offset = puff_offset[particle_index];
        start = emitter_origin + (offset - surface_up * dot(offset, surface_up));
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
        float2 ring = sqrt(max(0.0, 1.0 - z * z)) * float2(cos(theta), sin(theta));
        float3 direction = float3(ring.x, z, ring.y);
        float outward = dot(direction, surface_up);
        if (outward < 0.2) direction = normalize(direction + surface_up * (0.35 - outward));

        lifetime = 0.42 + r2 * 0.28 + burst * 0.06;
        velocity = direction * (12.0 + r1 * 7.0 + burst * 4.0);
        scale = (0.3 + r0 * 0.22) * (1.0 - burst * 0.15);
        start = emitter_origin + direction * (burst * 0.35 + spark * 0.01);
    }

    float life = clamp(1.0 - age / lifetime, 0.0, 1.0);
    float3 particle_position = start + velocity * dragTravel(age);

    float2 corner = corners[vertex_index];
    float3 forward = normalize(scene_data.camera_position.xyz - particle_position);
    float3 right = normalize(cross(scene_data.camera_up.xyz, forward));
    float3 up = cross(forward, right);
    float3 world_position = particle_position + (right * corner.x + up * corner.y) * scale * life;

    VertexOutput output;
    output.position = mul(scene_data.proj_view, float4(world_position, 1.0));
    output.color = float4(1.0, 1.0, 1.0, 1.0);
    output.uv = float2(corner.x + 0.5, 0.5 - corner.y);
    output.texture_index = push_constant.texture_index;
    return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) : SV_Target {
    return textures[input.texture_index].Sample(input.uv) * input.color;
}
