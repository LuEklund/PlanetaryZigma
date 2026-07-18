#version 450

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_frag_color;

layout(set = 1, binding = 0) uniform sampler2D textures[256];

layout(push_constant, std430) uniform pc {
  layout(offset = 80) uint texture_index;
} push_constant;

void main() {
  vec4 tex = texture(textures[push_constant.texture_index], in_uv) * in_color;
  out_frag_color = vec4(tex.rgb, tex.a);
}
