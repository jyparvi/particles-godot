shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float film_grain_amount : hint_range(0.0f, 1.0f) = 0.5f;
uniform uint frame_index = 0u;

// Apply film grain that changes each frame, with reduced strength in brighter pixels.
void fragment()
{
    vec3 color = textureLod(screen_texture, SCREEN_UV, 0.0f).rgb;
    uvec2 pixel = uvec2(FRAGCOORD.xy);
    uint hash = (pixel.x * 1597334677u) ^ (pixel.y * 3812015801u) ^ (frame_index * 2798796415u);
    hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15u)) * 0x846ca68bu;
    hash ^= hash >> 16u;
    float noise = (float(hash & 0x00ffffffu) / 16777216.0f) - 0.5f;
    float grain = noise * film_grain_amount * 0.6f * (1.0f - 0.8f * sqrt(max(dot(color, vec3(0.21f, 0.72f, 0.07f)), 0.0f)));
    COLOR = vec4(color * (1.0f + grain), 1.0f);
}
