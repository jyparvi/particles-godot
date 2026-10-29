#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct Particle
{
    vec3 position;
    vec3 velocity;
};

layout(set = 0, binding = 0, std430) restrict buffer ParticleBuffer
{
    Particle particles[];
};
layout(set = 0, binding = 3, std430) readonly restrict buffer D20Planes
{
    vec4 d20_planes[];
};
layout(rgba32f, set = 0, binding = 1) uniform writeonly image2D particlePositions;
layout(rgba32f, set = 0, binding = 4) uniform writeonly image2D particleVelocities;

layout(set = 0, binding = 2, std140) uniform SimulationParameters
{
    float delta_time;
    uint particle_count;
    uint initialize_particles;
    uint frame_index;
    uint d20_plane_count;
    mat4 d20_world_to_local;
    mat4 prev_d20_world_to_local;
    mat4 d20_local_to_world;
    float min_speed;
    float max_speed;
    uint particle_texture_width;
} params;

const float MIN_SPAWN_DISTANCE = 1.65f;
const float MAX_SPAWN_DISTANCE = 6.0f;
const float COLLISION_SKIN = 0.05f;
const float BOUNCINESS = 0.8f;

// Hash an unsigned integer.
uint hash(uint x)
{
    x = ((x >> 16u) ^ x) * 73244475u;
    x = ((x >> 16u) ^ x) * 73244475u;
    return (x >> 16u) ^ x;
}

// Generate a random float from three seed values.
float generate_hashed_random_float(uvec3 seed)
{
    uint value = hash(seed.x ^ hash(seed.y ^ hash(seed.z)));
    return uintBitsToFloat((value & 0x007fffffu) | 0x3f800000u) - 1.0f;
}

// Convert two uniform random values into a uniformly distributed unit direction.
vec3 sample_sphere_uniform(float u1, float u2)
{
    float phi = 6.28318530718f * u2;
    float cos_theta = 1.0f - 2.0f * u1;
    float sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    return vec3(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta);
}

// Initialize a particle within the sphere or respawn it on the outer surface.
void spawn_particle(inout Particle p, uint particle_id, bool initialize)
{
    float u1 = generate_hashed_random_float(uvec3(particle_id, params.frame_index, 0u));
    float u2 = generate_hashed_random_float(uvec3(particle_id, params.frame_index, 1u));
    vec3 direction = sample_sphere_uniform(u1, u2);
    float speed = mix(params.min_speed, params.max_speed, generate_hashed_random_float(uvec3(particle_id, params.frame_index, 2u)));

    float distance = MAX_SPAWN_DISTANCE;
    if (initialize)
    {
        distance = mix(MIN_SPAWN_DISTANCE, MAX_SPAWN_DISTANCE, generate_hashed_random_float(uvec3(particle_id, params.frame_index, 3u)));
        speed *= generate_hashed_random_float(uvec3(particle_id, params.frame_index, 4u)) < 0.5f ? -BOUNCINESS : 1.0f;
    }

    p.position = direction * distance;
    p.velocity = -direction * speed;
}

// Find where a local-space movement segment starting outside the D20 object intersects its surface.
bool intersect_segment_with_d20(vec3 origin, vec3 direction, out float hit_time, out vec3 local_normal)
{
    hit_time = 0.0f;
    local_normal = vec3(0.0f);
    float exit_time = 1.0f;

    for (uint i = 0u; i < params.d20_plane_count; i++)
    {
        vec4 plane = d20_planes[i];
        float distance = dot(plane.xyz, origin) + plane.w;
        float speed = dot(plane.xyz, direction);

        if (abs(speed) < 0.000001f)
        {
            if (distance > 0.0f)
            {
                return false;
            }

            continue;
        }

        float plane_time = -distance / speed;

        if (speed < 0.0f)
        {
            if (plane_time > hit_time)
            {
                hit_time = plane_time;
                local_normal = plane.xyz;
            }
        }
        else if (plane_time < exit_time)
        {
            exit_time = plane_time;
        }

        if (hit_time > exit_time)
        {
            return false;
        }
    }

    return hit_time > 0.0f;
}

// Check if a local point is inside the D20 object; if so, output the nearest face normal and signed distance.
bool find_containing_face(vec3 sample_position, out vec3 local_normal, out float signed_distance)
{
    local_normal = vec3(0.0f);
    signed_distance = -1.0e+30f;

    for (uint i = 0u; i < params.d20_plane_count; i++)
    {
        vec4 plane = d20_planes[i];
        float distance = dot(plane.xyz, sample_position) + plane.w;

        if (distance > 0.0f)
        {
            return false;
        }

        if (distance > signed_distance)
        {
            signed_distance = distance;
            local_normal = plane.xyz;
        }
    }

    return true;
}

// Transform a D20 object local-space normal to world space and normalize it.
vec3 local_normal_to_world(vec3 local_normal)
{
    return normalize(transpose(mat3(params.d20_world_to_local)) * local_normal);
}

// Reflect inward velocity off the surface and apply bounciness.
void bounce_velocity(inout vec3 velocity, vec3 world_normal)
{
    if (dot(velocity, world_normal) < 0.0f)
    {
        velocity = reflect(velocity, world_normal) * BOUNCINESS;
    }
}

// Advance one particle, resolve D20 collisions, and respawn at the outer sphere.
void main()
{
    uvec3 id = gl_GlobalInvocationID;
    if (id.x >= params.particle_count)
    {
        return;
    }

    Particle p;
    if (params.initialize_particles != 0u)
    {
        spawn_particle(p, id.x, true);
    }
    else
    {
        p = particles[id.x];
    }

    vec3 prev_position = p.position;
    vec3 next_position = prev_position + p.velocity * params.delta_time;

    vec3 local_start = (params.prev_d20_world_to_local * vec4(prev_position, 1.0f)).xyz;
    vec3 local_end = (params.d20_world_to_local * vec4(next_position, 1.0f)).xyz;
    vec3 local_direction = local_end - local_start;
    float hit_time = 0.0f;
    vec3 local_normal = vec3(0.0f);
    float signed_distance;

    if (intersect_segment_with_d20(local_start, local_direction, hit_time, local_normal))
    {
        vec3 world_normal = local_normal_to_world(local_normal);
        vec3 collision_point = mix(prev_position, next_position, hit_time);

        bounce_velocity(p.velocity, world_normal);

        next_position = collision_point + world_normal * COLLISION_SKIN + p.velocity * (params.delta_time * (1.0f - hit_time));
    }

    vec3 final_local_position = (params.d20_world_to_local * vec4(next_position, 1.0f)).xyz;

    if (find_containing_face(final_local_position, local_normal, signed_distance))
    {
        vec3 world_normal = local_normal_to_world(local_normal);
        vec3 local_surface = final_local_position - local_normal * signed_distance;

        bounce_velocity(p.velocity, world_normal);

        next_position = (params.d20_local_to_world * vec4(local_surface, 1.0f)).xyz + world_normal * COLLISION_SKIN;
    }

    p.position = next_position;

    if (dot(p.position, p.position) >= MAX_SPAWN_DISTANCE * MAX_SPAWN_DISTANCE && dot(p.position, p.velocity) > 0.0f)
    {
        spawn_particle(p, id.x, false);
    }

    particles[id.x] = p;

    ivec2 texel = ivec2(int(id.x % params.particle_texture_width), int(id.x / params.particle_texture_width));
    imageStore(particlePositions, texel, vec4(p.position, 0.0f));
    imageStore(particleVelocities, texel, vec4(p.velocity, 0.0f));
}
