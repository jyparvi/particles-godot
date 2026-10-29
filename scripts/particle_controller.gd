class_name ParticleController
extends Node3D

const MaxParticleCount := 1000000

@export var computeShader: RDShaderFile = preload("res://shaders/particle_compute.glsl")
@export_range(1, 1000000, 1) var particleCount := 500
@export_range(0.001, 1.0, 0.001, "or_greater") var particleSize := 0.05
@export_range(0.0, 10.0, 0.1, "or_greater") var minSpeed := 1.0
@export_range(0.0, 10.0, 0.1, "or_greater") var maxSpeed := 4.0
@export_range(0.0, 0.5, 0.001) var velocityStretch := 0.04
@export var rotationSpeed := Vector3(10.0, 15.0, 10.0)
@export var nearParticleColor := Color.RED
@export var farParticleColor := Color.YELLOW

@export_group("Glow")
@export var enableGlow := true
@export var glowColor := Color.WHITE
@export_range(0.0, 10.0, 0.01) var glowIntensity := 4.0
@export_range(0.25, 8.0, 0.01) var glowSharpness := 2.0

@export_group("Post Processing")
@export_range(0.0, 10.0, 0.01) var bloomAmount := 1.0
@export_range(0.0, 1.0, 0.01) var filmGrainAmount := 0.5

@onready var d20Mesh: MeshInstance3D = $D20/D20
@onready var particleRenderer: MultiMeshInstance3D = $Particles
@onready var fpsLabel: Label = $HUD/FPS
@onready var postProcessEnvironment: Environment = $WorldEnvironment.environment
@onready var filmGrain: ColorRect = $PostProcessing/FilmGrain
@onready var particleMaterial: ShaderMaterial = particleRenderer.material_override as ShaderMaterial

var d20PlaneCount := 0
var d20PlaneData := PackedByteArray()
var prevD20WorldToLocal := Transform3D.IDENTITY
var parameterData := PackedByteArray()
var simulation := Simulation.new()
var computeReady := false
var bufferParticleCount := 0

# Initialize rendering, post processing, and collision planes.
func _ready() -> void:
	particleRenderer.visible = false

	var vertices := PackedVector3Array()
	vertices.resize(6)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	particleRenderer.multimesh.mesh = mesh

	parameterData.resize(Simulation.ParameterBufferSize)
	simulation.buffers_ready.connect(BindParticleTextures, CONNECT_DEFERRED)
	prevD20WorldToLocal = d20Mesh.global_transform.affine_inverse()

	SetupPostProcessing()
	BuildD20Planes()

# Rotate the D20 object, update settings, and dispatch the particle simulation.
func _process(delta: float) -> void:
	particleCount = clampi(particleCount, 1, MaxParticleCount)
	var updateCompute := computeReady or bufferParticleCount == 0
	if updateCompute and particleCount != bufferParticleCount:
		RebuildParticleBuffer()

	UpdatePostProcessing()

	d20Mesh.global_rotate(Vector3.BACK, deg_to_rad(rotationSpeed.z) * delta)
	d20Mesh.global_rotate(Vector3.RIGHT, -deg_to_rad(rotationSpeed.x) * delta)
	d20Mesh.global_rotate(Vector3.UP, -deg_to_rad(rotationSpeed.y) * delta)

	var worldToLocal := d20Mesh.global_transform.affine_inverse()
	if updateCompute:
		particleMaterial.set_shader_parameter("d20_world_to_local", worldToLocal)
		parameterData.encode_float(0, delta)
		parameterData.encode_u32(4, bufferParticleCount)
		parameterData.encode_u32(12, Engine.get_process_frames())
		parameterData.encode_u32(16, d20PlaneCount)
		WriteTransform(parameterData, 32, worldToLocal)
		WriteTransform(parameterData, 96, prevD20WorldToLocal)
		WriteTransform(parameterData, 160, d20Mesh.global_transform)
		parameterData.encode_float(224, minSpeed)
		parameterData.encode_float(228, maxSpeed)
		parameterData.encode_u32(232, Simulation.ParticleTextureWidth)
	prevD20WorldToLocal = worldToLocal

	particleMaterial.set_shader_parameter("far_particle_color", farParticleColor)
	particleMaterial.set_shader_parameter("near_particle_color", nearParticleColor)
	particleMaterial.set_shader_parameter("particle_size", particleSize)
	particleMaterial.set_shader_parameter("velocity_stretch", velocityStretch)
	particleMaterial.set_shader_parameter("glow_color", glowColor)
	particleMaterial.set_shader_parameter("glow_intensity", glowIntensity if enableGlow else 0.0)
	particleMaterial.set_shader_parameter("glow_sharpness", glowSharpness)

	if updateCompute:
		RenderingServer.call_on_render_thread(simulation.UpdateCompute.bind(
			computeShader, d20PlaneData, parameterData.duplicate()))
		d20PlaneData = PackedByteArray()

	fpsLabel.text = "Particles: %d\nFPS: %d" % [particleCount, roundi(1.0 / maxf(delta, 0.0001))]

# Hide particles and release GPU resources on the rendering thread.
func _exit_tree() -> void:
	computeReady = false
	particleRenderer.visible = false
	RenderingServer.call_on_render_thread(simulation.ReleaseCompute)

# Resize particle instances and hide them until the GPU textures are ready.
func RebuildParticleBuffer() -> void:
	computeReady = false
	particleRenderer.visible = false
	particleMaterial.set_shader_parameter("particle_positions", null)
	particleMaterial.set_shader_parameter("particle_velocities", null)
	bufferParticleCount = particleCount

	var transforms := PackedFloat32Array()
	transforms.resize(particleCount * 12)
	for i in particleCount:
		transforms[i * 12] = 1.0
		transforms[i * 12 + 5] = 1.0
		transforms[i * 12 + 10] = 1.0

	particleRenderer.multimesh.instance_count = particleCount
	particleRenderer.multimesh.buffer = transforms

# Build normalized outward planes in the D20 object's local space.
func BuildD20Planes() -> void:
	var faces := d20Mesh.mesh.get_faces()
	var planes := PackedVector4Array()

	for i in range(0, faces.size(), 3):
		var a := faces[i]
		var normal := (faces[i + 1] - a).cross(faces[i + 2] - a)

		normal = normal.normalized()
		if normal.dot(a) < 0.0:
			normal = -normal

		planes.append(Vector4(normal.x, normal.y, normal.z, -normal.dot(a)))

	d20PlaneCount = planes.size()
	particleMaterial.set_shader_parameter("d20_planes", planes)
	particleMaterial.set_shader_parameter("d20_plane_count", d20PlaneCount)
	d20PlaneData = planes.to_byte_array()

# Configure bloom and apply the initial post-processing settings.
func SetupPostProcessing() -> void:
	postProcessEnvironment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	postProcessEnvironment.glow_hdr_threshold = 1.0
	postProcessEnvironment.glow_strength = 0.7
	UpdatePostProcessing()

# Apply bloom and film grain intensities and enable their effects when nonzero.
func UpdatePostProcessing() -> void:
	bloomAmount = clampf(bloomAmount, 0.0, 10.0)
	postProcessEnvironment.glow_enabled = bloomAmount > 0.0
	postProcessEnvironment.glow_intensity = bloomAmount
	
	filmGrainAmount = clampf(filmGrainAmount, 0.0, 1.0)
	filmGrain.visible = filmGrainAmount > 0.0
	filmGrain.material.set_shader_parameter("film_grain_amount", filmGrainAmount)
	filmGrain.material.set_shader_parameter("frame_index", Engine.get_process_frames())

# Bind the simulation textures and show particles.
func BindParticleTextures(positions: Texture2DRD, velocities: Texture2DRD) -> void:
	if not is_inside_tree():
		return

	particleMaterial.set_shader_parameter("particle_positions", positions)
	particleMaterial.set_shader_parameter("particle_velocities", velocities)
	computeReady = true
	particleRenderer.visible = true

# Write a transform as a column-major matrix for the compute shader.
func WriteTransform(data: PackedByteArray, offset: int, transform: Transform3D) -> void:
	var matrix := Projection(transform)
	for column in 4:
		for row in 4:
			data.encode_float(offset + column * 16 + row * 4, matrix[column][row])

class Simulation extends RefCounted:
	signal buffers_ready(positions: Texture2DRD, velocities: Texture2DRD)

	const ThreadGroupSize := 256
	const ParticleStride := 32
	const ParticleTextureWidth := 256
	const ParameterBufferSize := 240
	const UniformTypes := [
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		RenderingDevice.UNIFORM_TYPE_IMAGE,
		RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		RenderingDevice.UNIFORM_TYPE_IMAGE,
	]

	var rd: RenderingDevice
	var computeShader: RID
	var computePipeline: RID
	var particleBuffer: RID
	var d20PlaneBuffer: RID
	var parameterBuffer: RID
	var uniformSet: RID
	var positionTexture: RID
	var velocityTexture: RID
	var positionResource := Texture2DRD.new()
	var velocityResource := Texture2DRD.new()
	var particleCount := 0

	# Initialize GPU resources, rebuild particles when needed, and dispatch the simulation.
	func UpdateCompute(shaderFile: RDShaderFile, planes: PackedByteArray, parameters: PackedByteArray) -> void:
		if not computePipeline.is_valid():
			rd = RenderingServer.get_rendering_device()
			computeShader = rd.shader_create_from_spirv(shaderFile.get_spirv())
			computePipeline = rd.compute_pipeline_create(computeShader)
			d20PlaneBuffer = rd.storage_buffer_create(planes.size(), planes)
			parameterBuffer = rd.uniform_buffer_create(ParameterBufferSize, parameters)

		var rebuildParticles := particleCount != parameters.decode_u32(4)
		if rebuildParticles:
			RebuildParticleBuffer(parameters)

		parameters.encode_u32(8, int(rebuildParticles))
		rd.buffer_update(parameterBuffer, 0, ParameterBufferSize, parameters)

		var computeList := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(computeList, computePipeline)
		rd.compute_list_bind_uniform_set(computeList, uniformSet, 0)
		rd.compute_list_dispatch(computeList, ceili(float(particleCount) / ThreadGroupSize), 1, 1)
		rd.compute_list_end()

		if rebuildParticles:
			buffers_ready.emit(positionResource, velocityResource)

	# Recreate particle buffers and textures and bind them to the compute shader.
	func RebuildParticleBuffer(parameters: PackedByteArray) -> void:
		ReleaseParticleBuffer()
		particleCount = parameters.decode_u32(4)
		particleBuffer = rd.storage_buffer_create(particleCount * ParticleStride)
		positionTexture = CreateParticleTexture()
		velocityTexture = CreateParticleTexture()

		var uniforms: Array[RDUniform] = []
		var resources := [particleBuffer, positionTexture, parameterBuffer, d20PlaneBuffer, velocityTexture]
		for binding in resources.size():
			var uniform := RDUniform.new()
			uniform.binding = binding
			uniform.uniform_type = UniformTypes[binding]
			uniform.add_id(resources[binding])
			uniforms.append(uniform)
		uniformSet = rd.uniform_set_create(uniforms, computeShader, 0)

		positionResource.texture_rd_rid = positionTexture
		velocityResource.texture_rd_rid = velocityTexture

	# Create a GPU texture for sharing particle data with the render shader.
	func CreateParticleTexture() -> RID:
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.width = ParticleTextureWidth
		format.height = ceili(float(particleCount) / ParticleTextureWidth)
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		return rd.texture_create(format, RDTextureView.new())

	# Detach render textures and release particle buffers, textures, and bindings.
	func ReleaseParticleBuffer() -> void:
		positionResource.texture_rd_rid = RID()
		velocityResource.texture_rd_rid = RID()

		for resource in [uniformSet, velocityTexture, positionTexture, particleBuffer]:
			if resource.is_valid():
				rd.free_rid(resource)

		uniformSet = RID()
		velocityTexture = RID()
		positionTexture = RID()
		particleBuffer = RID()

	# Release all GPU simulation resources.
	func ReleaseCompute() -> void:
		if rd == null:
			return

		ReleaseParticleBuffer()

		for resource in [parameterBuffer, d20PlaneBuffer, computePipeline, computeShader]:
			if resource.is_valid():
				rd.free_rid(resource)

		parameterBuffer = RID()
		d20PlaneBuffer = RID()
		computePipeline = RID()
		computeShader = RID()
