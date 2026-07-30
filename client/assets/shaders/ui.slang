[[vk::binding(0, 0)]] Sampler2D textures[256];

struct Vertex {
    float2 position;
    float2 uv;
    float4 color;
    uint texture_index;
    uint is_sdf;
    uint2 padding;
};

struct PushConstant {
    Vertex *vertex_buffer;
    float2 screen_size;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
    nointerpolation uint texture_index : TEXCOORD1;
    nointerpolation uint is_sdf : TEXCOORD2;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];

    VertexOutput output;
    output.position = float4(vertex.position / push_constant.screen_size * 2.0 - 1.0, 0.0, 1.0);
    output.color = vertex.color;
    output.uv = vertex.uv;
    output.texture_index = vertex.texture_index;
    output.is_sdf = vertex.is_sdf;
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    float4 texel = textures[NonUniformResourceIndex(input.texture_index)].Sample(input.uv);
    if (input.is_sdf == 1) {
        float width = fwidth(texel.r);
        float coverage = smoothstep(0.5 - width, 0.5 + width, texel.r);
        return float4(input.color.rgb, input.color.a * coverage);
    }
    return texel * input.color;
}
