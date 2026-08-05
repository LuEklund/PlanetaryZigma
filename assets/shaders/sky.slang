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

[[vk::binding(0, 1)]] SamplerCube sky_cube;

struct VertexOutput {
    float4 position : SV_Position;
    float2 ndc : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
    float2 corner = float2((vertex_index << 1) & 2, vertex_index & 2);
    VertexOutput output;
    output.ndc = corner * 2.0 - 1.0;
    output.position = float4(output.ndc, 1.0, 1.0);
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    float4 ray = mul(scene_data.inverse_proj_rotation, float4(input.ndc, 1.0, 1.0));
    float3 direction = normalize(ray.xyz / ray.w);

    float3 base_color = sky_cube.Sample(direction).rgb;

    float sun = max(dot(direction, normalize(scene_data.global_light_direction)), 0.0);
    float3 glow = float3(1.0, 0.8, 0.5) * pow(sun, 8.0) * 0.3;
    float3 disc = float3(1.0, 0.95, 0.85) * pow(sun, 2000.0);

    return float4((base_color + glow + disc) * scene_data.light_color.xyz, 1.0);
}
