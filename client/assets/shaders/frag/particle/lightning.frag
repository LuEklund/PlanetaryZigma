#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) flat in uint in_texture_index;
layout(location = 3) in float in_lifetime;
layout(location = 4) flat in float in_seed;
layout(location = 0) out vec4 out_frag_color;

layout(set = 1, binding = 0) uniform sampler2D textures[256];

void main() {
  vec4 tex = texture(textures[nonuniformEXT(in_texture_index)], in_uv) * in_color;
  out_frag_color = vec4(tex.rgb, tex.a * 0.45);
}
