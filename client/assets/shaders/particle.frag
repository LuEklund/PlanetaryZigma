#version 450

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_frag_color;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

void main() {
  vec4 tex = texture(texSampler, in_uv) * in_color;
  out_frag_color = vec4(tex.rgb, tex.a);
}
