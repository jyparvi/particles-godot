# Godot GPU Particles

A particle simulation in Godot using compute shaders and the Forward+ renderer. Particles bounce off a rotating D20 object and respawn on an outer sphere.

## Features

- GPU particle simulation and collisions with the D20 object.
- GPU initialization with random positions and velocities on startup and particle-count changes.
- Automatic respawning on the outer sphere when a particle reaches it moving outward.
- Camera-facing particle billboards with velocity-based stretching.
- Particle colors based on distance to the D20 object's surface.
- Adjustable particle glow, bloom, and film grain.
- On-screen particle count and FPS.

## Requirements

- **Godot 4.7.2**.
- The **Forward+ renderer** and a GPU and graphics API that support [Godot compute shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html).
- Compatibility rendering and Web exports are unsupported because the simulation requires `RenderingDevice` compute shaders.

## Run the demo

1. Clone this repository.
2. In Godot's Project Manager, select **Import** and choose `project.godot`.
3. Open the project with Godot **4.7.2**.
4. Wait for Godot to import the textures, FBX model, and compute shader.
5. Press **F5** to run the project, or open `particles.tscn` and press **F6** to run the scene.

The scene starts with **500 particles**. Select the root **Particles** node in the Scene tree to adjust its **ParticleController** settings in the Inspector before running. During playback, use the **Remote** scene tree to change runtime values. The D20 object rotates automatically.

## Settings

| Setting | Description |
| --- | --- |
| Particle Count | Number of particles, clamped to 1–1,000,000. |
| Particle Size | Size of the particle billboards. |
| Min Speed / Max Speed | Range of initial particle speeds. |
| Velocity Stretch | Stretch the billboards along their movement direction in camera space. |
| Rotation Speed | Rotation speed around each world axis, in degrees per second. |
| Near Particle Color / Far Particle Color | Colors used near and far from the D20 object's surface. |
| Enable Glow / Glow Color / Glow Intensity / Glow Sharpness | Control the glow within each particle. |
| Bloom Amount / Film Grain Amount | Control the post-processing effects. |

Changing Particle Count recreates the GPU particle buffer and textures and restarts the particles. The upper limit is a code limit, not a performance guarantee; performance depends on the GPU and settings. Inspector changes made in the Remote scene tree during playback are temporary.

## Source files

| File | Purpose |
| --- | --- |
| [particle_controller.gd](scripts/particle_controller.gd) | Particle settings, GPU buffers and textures, D20 collision planes, compute dispatch, rendering setup, and particle count and FPS display. |
| [particle_compute.glsl](shaders/particle_compute.glsl) | Initializes particles, updates their positions, respawns them at the outer sphere, and resolves D20 collisions on the GPU. |
| [particle_render.gdshader](shaders/particle_render.gdshader) | Creates particle billboards and applies stretching, surface-distance colors, glow, and soft circular edges. |
| [film_grain.gdshader](shaders/film_grain.gdshader) | Applies screen-space film grain that changes each frame, with reduced strength in brighter pixels. |
| [particles.tscn](particles.tscn) | Demo scene, camera, lighting, D20 and sphere meshes, and post-processing. |

Particle positions and velocities are stored in a GPU buffer and shared with the render shader through two GPU textures. A MultiMesh draws one billboard per particle. The D20 object's mesh faces are converted to local-space planes at startup for collision checks.
