extends Node3D
# 3D MLS-MPM lab scene: dam-break water vs a sand castle, all on GPU compute.
# Run:  godot --path godot mpm.tscn -- --shot=/tmp/a.png --frames=240
# Interactive: right-drag orbit, wheel zoom, Space pause, R reset.

const NP := 100_000
const NG := 48
const DX := 1.0 / NG
const DT := 0.0003          # CFL: c=sqrt(E/rho)~55, dx/c~3.8e-4
const SUBSTEPS := 7
const E_WATER := 900.0
const E_SAND := 3000.0
const GRAV := 8.0
const TEXW := 512

var rd: RenderingDevice
var shader_rid: RID
var pipeline: RID
var pbuf: RID
var gbuf: RID
var pos_tex_rd: RID
var uset: RID
var pos_tex2d: Texture2DRD

var paused := false
var frame_count := 0
var shot_path := ""
var shot_frames := 240
var record_dir := ""
var sim_ms := 0.0

var cam: Camera3D
var pivot: Node3D
var yaw := 0.55
var pitch := 0.35
var dist := 62.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			shot_frames = int(a.substr(9))
		elif a.begins_with("--record="):
			record_dir = a.substr(9)
			DirAccess.make_dir_recursive_absolute(record_dir)
	_build_env()
	_init_compute()
	_build_particles_mesh()


func _particle_seed() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(NP * 32)
	var idx := 0
	var n_water := int(NP * 0.55)
	for i in NP:
		var px: float
		var py: float
		var pz: float
		var m: float
		if i < n_water:
			# 水柱:右侧高墙
			px = 0.66 + randf() * 0.30
			py = 0.03 + randf() * 0.52
			pz = 0.06 + randf() * 0.88
			m = 0.0
		else:
			var r := randf()
			if r < 0.62:
				# 城堡基座
				px = 0.16 + randf() * 0.24
				py = 0.02 + randf() * 0.17
				pz = 0.30 + randf() * 0.40
				m = 1.0
			else:
				# 塔楼
				px = 0.22 + randf() * 0.12
				py = 0.19 + randf() * 0.20
				pz = 0.42 + randf() * 0.16
				m = 1.0
		# pos
		f[idx] = px; f[idx + 1] = py; f[idx + 2] = pz; f[idx + 3] = m
		# vel + J/Jp
		f[idx + 4] = 0.0; f[idx + 5] = 0.0; f[idx + 6] = 0.0; f[idx + 7] = 1.0
		# C rows: zero
		for k in range(8, 20):
			f[idx + k] = 0.0
		# F rows: identity
		f[idx + 20] = 1.0; f[idx + 21] = 0.0; f[idx + 22] = 0.0; f[idx + 23] = 0.0
		f[idx + 24] = 0.0; f[idx + 25] = 1.0; f[idx + 26] = 0.0; f[idx + 27] = 0.0
		f[idx + 28] = 0.0; f[idx + 29] = 0.0; f[idx + 30] = 1.0; f[idx + 31] = 0.0
		idx += 32
	return f


func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	var src := load("res://mpm.glsl") as RDShaderFile
	shader_rid = rd.shader_create_from_spirv(src.get_spirv())
	pipeline = rd.compute_pipeline_create(shader_rid)

	pbuf = rd.storage_buffer_create(NP * 32 * 4, _particle_seed().to_byte_array())
	var gz := PackedByteArray()
	gz.resize(NG * NG * NG * 4 * 4)
	gbuf = rd.storage_buffer_create(gz.size(), gz)

	var fmt := RDTextureFormat.new()
	fmt.width = TEXW
	fmt.height = (NP + TEXW - 1) / TEXW
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zt := PackedByteArray()
	zt.resize(fmt.width * fmt.height * 16)
	pos_tex_rd = rd.texture_create(fmt, RDTextureView.new(), [zt])
	pos_tex2d = Texture2DRD.new()
	pos_tex2d.texture_rd_rid = pos_tex_rd

	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(pbuf)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(gbuf)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u2.binding = 2
	u2.add_id(pos_tex_rd)
	uset = rd.uniform_set_create([u0, u1, u2], shader_rid, 0)


func _params(mode: int) -> PackedByteArray:
	var f := PackedFloat32Array([
		DT, DX, float(NG), GRAV,
		float(mode), float(NP), float(NG), E_WATER,
		E_SAND, float(frame_count) * 0.016, 0.0, 0.0,
	])
	# inv_dx 放在第 3 个槽位:上面写错了就地修正
	f[2] = 1.0 / DX
	return f.to_byte_array()


func _sim_substep(cl: int) -> void:
	var cell_groups := (NG * NG * NG + 63) / 64
	var part_groups := (NP + 63) / 64
	var pc := _params(0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, cell_groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	pc = _params(1)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, part_groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	pc = _params(2)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, cell_groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	pc = _params(3)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, part_groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _process(_delta: float) -> void:
	if paused:
		return
	frame_count += 1
	var t0 := Time.get_ticks_usec()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	for s in SUBSTEPS:
		_sim_substep(cl)
	rd.compute_list_end()
	sim_ms = lerpf(sim_ms, (Time.get_ticks_usec() - t0) / 1000.0, 0.1)
	if record_dir != "":
		if frame_count % 3 == 0 and frame_count <= shot_frames:
			var img := get_viewport().get_texture().get_image()
			img.save_png(record_dir + "/r%04d.png" % frame_count)
		if frame_count > shot_frames:
			print("recording done: ", record_dir)
			get_tree().quit()
	elif shot_path != "" and frame_count == shot_frames:
		_take_shot()


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot_path)
	print("shot saved: ", shot_path, "  fps=", Engine.get_frames_per_second(),
		"  particles=", NP, "  grid=", NG, "  substeps=", SUBSTEPS,
		"  cpu_submit_ms=", "%.2f" % sim_ms)
	for pi in [60000, 99000]:
		var raw := rd.buffer_get_data(pbuf, pi * 128, 128)
		var fl := raw.to_float32_array()
		print("p", pi, " pos=", [fl[0], fl[1], fl[2]], " mat=", fl[3],
			" vel=", [fl[4], fl[5], fl[6]], " jp=", fl[7],
			" F0=", [fl[20], fl[21], fl[22]], " F1=", [fl[24], fl[25], fl[26]],
			" F2=", [fl[28], fl[29], fl[30]])
	get_tree().quit()


func _exit_tree() -> void:
	if rd == null:
		return
	pos_tex2d.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(func() -> void:
		rd.free_rid(pbuf)
		rd.free_rid(gbuf)
		rd.free_rid(pos_tex_rd)
		rd.free_rid(shader_rid))


func _build_particles_mesh() -> void:
	var verts := PackedVector3Array()
	verts.resize(NP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://mpm_particles.gdshader")
	mat.set_shader_parameter("pos_tex", pos_tex2d)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.extra_cull_margin = 64.0
	add_child(mi)


func _build_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	add_child(sun)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.20, 0.26)
	sky_mat.sky_horizon_color = Color(0.32, 0.36, 0.42)
	sky_mat.ground_bottom_color = Color(0.10, 0.10, 0.12)
	sky_mat.ground_horizon_color = Color(0.28, 0.30, 0.34)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# 地板参照面
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(44.0, 44.0)
	floor_mesh.mesh = pm
	floor_mesh.position = Vector3(0.0, 0.0, 0.0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.16, 0.17, 0.20)
	fm.roughness = 0.9
	floor_mesh.material_override = fm
	add_child(floor_mesh)
	pivot = Node3D.new()
	pivot.position = Vector3(0.0, 8.0, 0.0)
	add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 45.0
	pivot.add_child(cam)
	_update_cam()


func _update_cam() -> void:
	var cp := cos(pitch)
	var eye := Vector3(dist * cp * sin(yaw), dist * sin(pitch), -dist * cp * cos(yaw))
	cam.position = eye
	cam.look_at_from_position(pivot.position + eye, pivot.position, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw += event.relative.x * 0.005
		pitch = clampf(pitch + event.relative.y * 0.004, 0.05, 1.3)
		_update_cam()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist * 0.94, 20.0, 160.0)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist * 1.06, 20.0, 160.0)
			_update_cam()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE:
			paused = not paused
		elif event.keycode == KEY_R:
			rd.buffer_update(pbuf, 0, NP * 32 * 4, _particle_seed().to_byte_array())
			frame_count = 0
