// Fullscreen post chain: bloom prefilter -> blur (x, y) -> composite (bloom, tone, grade) -> FXAA.
// Passes reuse the world push constant; their parameters ride in the model matrix slot.

[[vk::binding(0, 1)]]
Sampler2D textures[256];

struct PostPush {
    float4 params;   // x: second texture index, y: strength/threshold, zw: blur step (uv)
    float4 grade;    // x: exposure, y: saturation, z: vignette, w: unused
    float4 unused0;
    float4 unused1;
    uint64_t vertex_buffer;
    uint64_t joint_matrices;
    uint source;
};
[[vk::push_constant]]
PostPush push;

struct Fullscreen {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
Fullscreen fullscreen_vert(uint vertex_index: SV_VertexID) {
    float2 corner = float2((vertex_index << 1) & 2, vertex_index & 2);
    Fullscreen output;
    output.uv = corner;
    output.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float2 texelOf(Sampler2D image) {
    uint width, height;
    image.GetDimensions(width, height);
    return 1.0 / float2(width, height);
}

// Downsample to half resolution and keep only what is brighter than the threshold (soft knee).
[shader("fragment")]
float4 bloom_prefilter_frag(Fullscreen input) : SV_Target {
    Sampler2D scene = textures[push.source];
    float2 texel = texelOf(scene);
    float3 color = (scene.Sample(input.uv + texel * float2(-1, -1)).rgb +
                    scene.Sample(input.uv + texel * float2(1, -1)).rgb +
                    scene.Sample(input.uv + texel * float2(-1, 1)).rgb +
                    scene.Sample(input.uv + texel * float2(1, 1)).rgb) * 0.25;
    float threshold = push.params.y;
    float knee = threshold * 0.5;
    float brightness = max(color.r, max(color.g, color.b));
    float soft = clamp(brightness - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contribution = max(soft, brightness - threshold) / max(brightness, 1e-4);
    return float4(color * contribution, 1.0);
}

// 9-tap gaussian along push.params.zw.
[shader("fragment")]
float4 bloom_blur_frag(Fullscreen input) : SV_Target {
    Sampler2D source = textures[push.source];
    float2 step = push.params.zw;
    const float weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 color = source.Sample(input.uv).rgb * weights[0];
    for (int tap = 1; tap < 5; tap++) {
        color += source.Sample(input.uv + step * tap).rgb * weights[tap];
        color += source.Sample(input.uv - step * tap).rgb * weights[tap];
    }
    return float4(color, 1.0);
}

// Values under the shoulder pass through unchanged; brighter ones roll off instead of clipping.
float3 softClip(float3 color) {
    const float shoulder = 0.8;
    float3 over = max(color - shoulder, 0.0);
    return min(color, shoulder) + over / (1.0 + over / (1.0 - shoulder));
}

[shader("fragment")]
float4 composite_frag(Fullscreen input) : SV_Target {
    float3 scene = textures[push.source].Sample(input.uv).rgb;
    float3 bloom = textures[uint(push.params.x)].Sample(input.uv).rgb;
    float3 color = (scene + bloom * push.params.y) * push.grade.x;
    color = softClip(color);
    float grey = luminance(color);
    color = lerp(float3(grey, grey, grey), color, push.grade.y);
    float2 centered = input.uv - 0.5;
    color *= 1.0 - push.grade.z * dot(centered, centered) * 2.0;
    return float4(color, 1.0);
}

// FXAA (Lottes' compact variant): blur only along detected edges.
[shader("fragment")]
float4 fxaa_frag(Fullscreen input) : SV_Target {
    Sampler2D image = textures[push.source];
    if (push.params.x < 0.5) return float4(image.Sample(input.uv).rgb, 1.0);
    float2 texel = texelOf(image);
    const float reduce_min = 1.0 / 128.0;
    const float reduce_mul = 1.0 / 8.0;
    const float span_max = 8.0;

    float3 north_west = image.Sample(input.uv + texel * float2(-1, -1)).rgb;
    float3 north_east = image.Sample(input.uv + texel * float2(1, -1)).rgb;
    float3 south_west = image.Sample(input.uv + texel * float2(-1, 1)).rgb;
    float3 south_east = image.Sample(input.uv + texel * float2(1, 1)).rgb;
    float3 middle = image.Sample(input.uv).rgb;
    float luma_nw = luminance(north_west);
    float luma_ne = luminance(north_east);
    float luma_sw = luminance(south_west);
    float luma_se = luminance(south_east);
    float luma_m = luminance(middle);
    float luma_min = min(luma_m, min(min(luma_nw, luma_ne), min(luma_sw, luma_se)));
    float luma_max = max(luma_m, max(max(luma_nw, luma_ne), max(luma_sw, luma_se)));

    float2 direction = float2(-((luma_nw + luma_ne) - (luma_sw + luma_se)), (luma_nw + luma_sw) - (luma_ne + luma_se));
    float reduce = max((luma_nw + luma_ne + luma_sw + luma_se) * 0.25 * reduce_mul, reduce_min);
    float scale = 1.0 / (min(abs(direction.x), abs(direction.y)) + reduce);
    direction = clamp(direction * scale, -span_max, span_max) * texel;

    float3 near_pair = 0.5 * (image.Sample(input.uv + direction * (1.0 / 3.0 - 0.5)).rgb +
                              image.Sample(input.uv + direction * (2.0 / 3.0 - 0.5)).rgb);
    float3 far_pair = near_pair * 0.5 + 0.25 * (image.Sample(input.uv - direction * 0.5).rgb +
                                                image.Sample(input.uv + direction * 0.5).rgb);
    float luma_far = luminance(far_pair);
    float3 color = (luma_far < luma_min || luma_far > luma_max) ? near_pair : far_pair;
    return float4(color, 1.0);
}
