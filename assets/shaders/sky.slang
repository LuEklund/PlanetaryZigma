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

static const float3 night_zenith = float3(0.01, 0.015, 0.05);
static const float3 night_horizon = float3(0.05, 0.06, 0.12);
static const float3 sunset_color = float3(1.0, 0.45, 0.2);

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    float4 ray = mul(scene_data.inverse_proj_rotation, float4(input.ndc, 1.0, 1.0));
    float3 direction = normalize(ray.xyz / ray.w);

    float3 up = normalize(scene_data.camera_position);
    float3 sun_direction = normalize(scene_data.to_sun);
    float sun_height = dot(sun_direction, up);
    float day = smoothstep(-0.10, 0.25, sun_height);
    float elevation = saturate(dot(direction, up));
    float horizon_weight = pow(1.0 - elevation, 3.0);

    float3 day_sky = lerp(scene_data.sky_zenith.rgb, scene_data.sky_horizon.rgb, horizon_weight);
    float3 night_sky = lerp(night_zenith, night_horizon, horizon_weight);
    float twilight = saturate(1.0 - abs(sun_height) / 0.3);
    float3 flat_view = direction - up * dot(direction, up);
    float3 flat_sun = sun_direction - up * sun_height;
    float sun_side = saturate(dot(flat_view, flat_sun) / max(length(flat_view) * length(flat_sun), 0.0001) * 0.5 + 0.5);
    float3 sky_color = lerp(night_sky, day_sky, day);
    sky_color = lerp(sky_color, sunset_color, twilight * horizon_weight * sun_side * 0.7);

    float3 stars = sky_cube.Sample(direction).rgb * (1.0 - day) * 0.6;
    float sun = max(dot(direction, sun_direction), 0.0);
    float3 glow = float3(1.0, 0.8, 0.5) * pow(sun, 8.0) * 0.3 * day;
    float3 disc = float3(1.0, 0.95, 0.85) * pow(sun, 2000.0);
    sky_color = sky_color + stars + glow + disc;

    float outer = scene_data.planet_radius + 10;
    float t = dot(-scene_data.camera_position, direction);
    float d_sq = dot(scene_data.camera_position, scene_data.camera_position) - t * t;
    float haze = 0;
    if (d_sq < outer * outer) {
        float half_chord = sqrt(outer * outer - d_sq);
        float air = max((t + half_chord) - max(t - half_chord, 0), 0);
        haze = smoothstep(0, 250, air);
    }

    float3 haze_color = lerp(night_horizon, scene_data.sky_horizon.rgb, day);
    return float4(lerp(sky_color, haze_color, haze), 1.0);
}
