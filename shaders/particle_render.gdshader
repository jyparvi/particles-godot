shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, blend_mix, depth_draw_never, skip_vertex_transform;

uniform sampler2D particle_positions : filter_nearest, repeat_disable;
uniform sampler2D particle_velocities : filter_nearest, repeat_disable;
uniform vec4 d20_planes[20];

uniform float particle_size = 0.05f;
uniform vec4 far_particle_color : source_color = vec4(1.0f, 1.0f, 0.0f, 1.0f);
uniform vec4 near_particle_color : source_color = vec4(1.0f, 0.0f, 0.0f, 1.0f);
uniform float velocity_stretch : hint_range(0.0f, 0.5f) = 0.04f;
uniform vec4 glow_color : source_color = vec4(1.0f);
uniform float glow_intensity = 4.0f;
uniform float glow_sharpness = 2.0f;
uniform mat4 d20_world_to_local;
uniform uint d20_plane_count;

const int PARTICLE_TEXTURE_WIDTH = 256;
const float COLOR_TRANSITION_DISTANCE = 4.0f;
const vec2 QUAD_VERTICES[6] = vec2[6](
    vec2(-1.0f, -1.0f),
    vec2( 1.0f, -1.0f),
    vec2(-1.0f,  1.0f),
    vec2(-1.0f,  1.0f),
    vec2( 1.0f, -1.0f),
    vec2( 1.0f,  1.0f)
);

varying mediump vec4 particle_color;

// Approximate the particle's distance to the D20 object's surface.
float distance_to_d20_surface(vec3 world_position)
{
    vec3 local_position = (d20_world_to_local * vec4(world_position, 1.0f)).xyz;
    float signed_distance = -1.0e+30f;
    for (uint i = 0u; i < d20_plane_count; i++)
    {
        vec4 plane = d20_planes[i];
        signed_distance = max(signed_distance, dot(plane.xyz, local_position) + plane.w);
    }

    return abs(signed_distance);
}

// Compute a camera-facing particle vertex with velocity-based stretching and distance-based color.
void vertex()
{
    ivec2 texel = ivec2(INSTANCE_ID % PARTICLE_TEXTURE_WIDTH, INSTANCE_ID / PARTICLE_TEXTURE_WIDTH);
    vec4 particle = texelFetch(particle_positions, texel, 0);
    vec3 velocity = texelFetch(particle_velocities, texel, 0).xyz;

    POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(particle.xyz, 1.0f));
    
    vec2 corner = QUAD_VERTICES[VERTEX_ID];
    vec2 billboard_offset = corner * particle_size;
    vec2 view_velocity = (VIEW_MATRIX * vec4(velocity, 0.0f)).xy;
    float view_speed = length(view_velocity);
    
    if (velocity_stretch > 0.0f && view_speed > 0.0001f)
    {
        vec2 motion_direction = view_velocity / view_speed;
        vec2 side_direction = vec2(motion_direction.y, -motion_direction.x);
        float half_length = particle_size + view_speed * velocity_stretch * 0.5f;
        billboard_offset = side_direction * corner.x * particle_size + motion_direction * corner.y * half_length;
    }

    POSITION.xy += billboard_offset * vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
    UV = corner * 0.5f + 0.5f;
    float near_surface = clamp(1.0f - distance_to_d20_surface(particle.xyz) / COLOR_TRANSITION_DISTANCE, 0.0f, 1.0f);
    particle_color = mix(far_particle_color, near_particle_color, near_surface);
}

// Compute the particle's final color with glow and a soft circular edge.
void fragment()
{
    float radius = length(UV - 0.5f) * 2.0f;
    float edge = 1.0f - smoothstep(0.84f, 1.0f, radius);
    float core = pow(clamp(1.0f - radius, 0.0f, 1.0f), max(glow_sharpness, 0.01f));
    float glow = core * glow_intensity;
    vec3 color = mix(particle_color.rgb, glow_color.rgb, clamp(glow, 0.0f, 1.0f)) * (1.0f + glow);
    ALBEDO = color;
    ALPHA = particle_color.a * edge;
}
