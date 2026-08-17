extends Node3D
# Sandcastle 3D, Godot vertical slice.
# Heightfield beach + GPU shallow-water waves (compute shader, pipe model).
# Run headless verification:  godot --path godot -- --shot=/tmp/shot.png --frames=120 --wave

const N := 192
const SEA := 0.9

var rd: RenderingDevice
var shader_rid: RID
var pipeline: RID
var field_tex := []          # two RD textures, ping-pong
var flux_tex: RID
var uniform_sets := []       # [read=0 write=1], [read=1 write=0]
var cur := 0

var field_tex2d: Texture2DRD
var sim_time := 0.0
var wave_t := -1.0
var wave_amp := 0.0
var wave_dur := 0.0

var shot_path := ""
var shot_frames := 90
var auto_wave := false
var frame_count := 0

var cam_pivot: Node3D
var cam: Camera3D
var yaw := 0.34
var pitch := 0.46
var dist := 108.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			shot_frames = int(a.substr(9))
		elif a == "--wave":
			auto_wave = true
	_build_environment()
	_build_camera()
	var img := _gen_field_image()
	_init_compute(img)
	_build_terrain()
	_build_water()


func _gen_field_image() -> Image:
	var img := Image.create(N, N, false, Image.FORMAT_RGBAF)
	for z in N:
		var t := float(z) / float(N)
		for x in N:
			var h := 1.55 - 1.35 * smoothstep(0.0, 1.0, clampf((t - 0.18) / 0.55, 0.0, 1.0))
			h += 0.05 * sin(x * 0.11) + 0.04 * sin(x * 0.05 + z * 0.07) + 0.02 * sin(z * 0.23)
			h = maxf(0.05, h)
			var w := maxf(0.0, SEA - h)
			var m := 1.0 if w > 0.0 else (0.6 if h < SEA + 0.12 else 0.08)
			img.set_pixel(x, z, Color(h, w, m, 0.0))
	return img


func _init_compute(img: Image) -> void:
	rd = RenderingServer.get_rendering_device()
	var src := load("res://sim.glsl") as RDShaderFile
	var spirv := src.get_spirv()
	shader_rid = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader_rid)

	var fmt := RDTextureFormat.new()
	fmt.width = N
	fmt.height = N
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	var data := img.get_data()
	for i in 2:
		field_tex.append(rd.texture_create(fmt, RDTextureView.new(), [data]))
	var zero := PackedByteArray()
	zero.resize(N * N * 16)
	flux_tex = rd.texture_create(fmt, RDTextureView.new(), [zero])

	for i in 2:
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u0.binding = 0
		u0.add_id(field_tex[i])
		var u1 := RDUniform.new()
		u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u1.binding = 1
		u1.add_id(field_tex[1 - i])
		var u2 := RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u2.binding = 2
		u2.add_id(flux_tex)
		uniform_sets.append(rd.uniform_set_create([u0, u1, u2], shader_rid, 0))

	field_tex2d = Texture2DRD.new()
	field_tex2d.texture_rd_rid = field_tex[0]


func _push_params(dt: float, surge: float, damp: float, mode: int) -> PackedByteArray:
	var buf := PackedFloat32Array([dt, SEA, surge, damp])
	var raw := buf.to_byte_array()
	var ints := PackedInt32Array([mode, N, 0, 0])
	raw.append_array(ints.to_byte_array())
	return raw


func _sim_step(dt: float, surge: float) -> void:
	var damp := 0.9985 if wave_t >= 0.0 else 0.996
	var groups := (N + 7) / 8
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_sets[cur], 0)
	var pc0 := _push_params(dt, surge, damp, 0)
	rd.compute_list_set_push_constant(cl, pc0, pc0.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_add_barrier(cl)
	var pc1 := _push_params(dt, surge, damp, 1)
	rd.compute_list_set_push_constant(cl, pc1, pc1.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_end()
	cur = 1 - cur
	field_tex2d.texture_rd_rid = field_tex[cur]


func start_wave(amp: float, dur: float) -> void:
	wave_amp = amp
	wave_dur = dur
	wave_t = 0.0


func _process(delta: float) -> void:
	var dt := minf(delta, 0.033)
	sim_time += dt
	var surge := 0.025 * sin(sim_time * 1.6)
	if wave_t >= 0.0:
		wave_t += dt
		var ph := sin(PI * clampf(wave_t / wave_dur, 0.0, 1.0))
		surge += wave_amp * ph * ph
		if wave_t > wave_dur + 2.5:
			wave_t = -1.0
	for s in 2:
		_sim_step(dt * 0.5, surge)

	frame_count += 1
	if auto_wave and frame_count == 30:
		start_wave(0.5, 2.6)
	if shot_path != "" and frame_count == shot_frames:
		_take_shot()


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot_path)
	print("shot saved: ", shot_path, "  fps=", Engine.get_frames_per_second())
	get_tree().quit()


func _exit_tree() -> void:
	if rd == null:
		return
	field_tex2d.texture_rd_rid = RID()   # 先解除材质引用,再释放 RD 资源
	RenderingServer.call_on_render_thread(func() -> void:
		for t in field_tex:
			rd.free_rid(t)
		rd.free_rid(flux_tex)
		rd.free_rid(shader_rid))


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(N, N)
	plane.subdivide_width = N - 2
	plane.subdivide_depth = N - 2
	var mat := ShaderMaterial.new()
	mat.shader = load("res://terrain.gdshader")
	mat.set_shader_parameter("field_tex", field_tex2d)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.extra_cull_margin = 16.0
	add_child(mi)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(N, N)
	plane.subdivide_width = N - 2
	plane.subdivide_depth = N - 2
	var mat := ShaderMaterial.new()
	mat.shader = load("res://water.gdshader")
	mat.set_shader_parameter("field_tex", field_tex2d)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.extra_cull_margin = 16.0
	add_child(mi)


func _build_camera() -> void:
	cam_pivot = Node3D.new()
	cam_pivot.position = Vector3(0.0, 0.8, -6.0)
	add_child(cam_pivot)
	cam = Camera3D.new()
	cam.fov = 50.0
	cam_pivot.add_child(cam)
	_update_cam()


func _update_cam() -> void:
	var cp := cos(pitch)
	var eye := Vector3(dist * cp * sin(yaw), dist * sin(pitch), -dist * cp * cos(yaw))
	cam.position = eye
	cam.look_at_from_position(cam_pivot.position + eye, cam_pivot.position, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw += event.relative.x * 0.005
		pitch = clampf(pitch + event.relative.y * 0.004, 0.15, 1.25)
		_update_cam()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist * 0.94, 40.0, 320.0)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist * 1.06, 40.0, 320.0)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			start_wave(0.5, 2.6)


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 35.0, 0.0)
	sun.light_energy = 0.9
	add_child(sun)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.80, 0.92)
	sky_mat.sky_horizon_color = Color(0.91, 0.96, 0.98)
	sky_mat.ground_bottom_color = Color(0.91, 0.90, 0.84)
	sky_mat.ground_horizon_color = Color(0.91, 0.96, 0.98)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.38
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.91, 0.96)
	env.fog_density = 0.0012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
