import scene;

[[vk::binding(0, 1)]]
SamplerCube sky_cube;

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

    float sun = max(dot(direction, normalize(scene_data.to_sun)), 0.0);
    float3 glow = float3(1.0, 0.8, 0.5) * pow(sun, 8.0) * 0.3;
    float3 disc = float3(1.0, 0.95, 0.85) * pow(sun, 2000.0);
    float3 sky_color = (base_color + glow + disc) * scene_data.light_color.xyz;

    float outer = scene_data.planet_radius + 10;
    float t = dot(-scene_data.camera_position, direction);
    float d_sq = dot(scene_data.camera_position, scene_data.camera_position) - t * t;
    float haze = 0;
    if (d_sq < outer * outer) {
        float half_chord = sqrt(outer * outer - d_sq);
        float air = max((t + half_chord) - max(t - half_chord, 0), 0);
        haze = smoothstep(0, 250, air);
    }

    return float4(lerp(sky_color, fog_color, haze), 1.0);
}
