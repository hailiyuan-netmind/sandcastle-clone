extends Node3D
# Sandcastle 3D, Godot vertical slice.
# GPU compute sim (water pipe model + sand repose/erosion) + sculpting tools + HUD.
# Headless verification:
#   godot --path godot -- --shot=/tmp/a.png --frames=420 --demo
# Interactive: left drag = tool, right drag = orbit, wheel = zoom, 1-5 tools,
#              [ ] brush size, N = wave, Space = pause.

const N := 192
const SEA := 0.9
const TOOLS := ["pour", "dig", "water", "tamp", "flag"]
const TOOL_LABELS := ["🏰 堆沙", "⛏ 挖沙", "💧 洒水", "🔨 夯实", "🚩 插旗"]

var rd: RenderingDevice
var shader_rid: RID
var pipeline: RID
var field_tex := []
var flux_tex: RID
var sflux_tex: RID
var bucket_buf: RID
var uniform_sets := []
var cur := 0
var field_tex2d: Texture2DRD

var shadow: Image                 # low-rate CPU copy for picking / flag / stats
var shadow_tick := 0

var sim_time := 0.0
var paused := false
var wave_t := -1.0
var wave_amp := 0.0
var wave_dur := 0.0
var wave_count := 0
var next_timer := 25.0
var auto_waves := true
var survived := 0
var bucket := 2800.0
var height_cm := 0

var tool_idx := 0
var brush_r := 6.0
var brushing := false
var brush_pos := Vector2.ZERO

var flag_node: Node3D
var flag_cell := Vector2i(-1, -1)
var flag_base_h := 0.0
var flag_washed := false

var cam_pivot: Node3D
var cam: Camera3D
var yaw := 0.34
var pitch := 0.46
var dist := 108.0
var sun_vec := Vector3(0.45, 0.62, 0.34)

var hud_stats: Label
var hud_msg: Label
var msg_timer := 0.0
var tool_buttons := []

var shot_path := ""
var shot_frames := 90
var demo := false
var frame_count := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--frames="):
			shot_frames = int(a.substr(9))
		elif a == "--wave":
			auto_waves = false
			call_deferred("start_wave", 0.5, 2.6)
		elif a == "--demo":
			demo = true
			auto_waves = false
	_build_environment()
	_build_camera()
	var img := _gen_field_image()
	shadow = img
	_init_compute(img)
	_build_terrain()
	_build_water()
	_build_flag()
	_build_hud()


# ---------------- field / compute ----------------

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
	shader_rid = rd.shader_create_from_spirv(src.get_spirv())
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
	var zero := PackedByteArray()
	zero.resize(N * N * 16)
	for i in 2:
		field_tex.append(rd.texture_create(fmt, RDTextureView.new(), [data]))
	flux_tex = rd.texture_create(fmt, RDTextureView.new(), [zero])
	sflux_tex = rd.texture_create(fmt, RDTextureView.new(), [zero])

	var bzero := PackedByteArray()
	bzero.resize(8)
	bucket_buf = rd.storage_buffer_create(8, bzero)

	for i in 2:
		var us := []
		for b in 4:
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.binding = b
			u.add_id([field_tex[i], field_tex[1 - i], flux_tex, sflux_tex][b])
			us.append(u)
		var ub := RDUniform.new()
		ub.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		ub.binding = 4
		ub.add_id(bucket_buf)
		us.append(ub)
		uniform_sets.append(rd.uniform_set_create(us, shader_rid, 0))

	field_tex2d = Texture2DRD.new()
	field_tex2d.texture_rd_rid = field_tex[0]


func _params(dt: float, surge: float, damp: float, mode: int, tool: int) -> PackedByteArray:
	var f := PackedFloat32Array([
		dt, SEA, surge, damp,
		float(mode), float(N), float(tool), 0.0,
		brush_pos.x, brush_pos.y, brush_r, 9.0,
	])
	return f.to_byte_array()


func _sim_step(dt: float, surge: float) -> void:
	var damp := 0.9985 if wave_t >= 0.0 else 0.996
	var tool := -1
	if brushing and tool_idx < 4:
		tool = tool_idx
	var groups := (N + 7) / 8
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	# water: flux + integrate
	rd.compute_list_bind_uniform_set(cl, uniform_sets[cur], 0)
	var pc := _params(dt, surge, damp, 0, -1)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_add_barrier(cl)
	pc = _params(dt, surge, damp, 1, -1)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_add_barrier(cl)
	cur = 1 - cur
	# sand: flux + integrate (+ tools)
	rd.compute_list_bind_uniform_set(cl, uniform_sets[cur], 0)
	pc = _params(dt, surge, damp, 2, -1)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_add_barrier(cl)
	pc = _params(dt, surge, damp, 3, tool)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_end()
	cur = 1 - cur
	field_tex2d.texture_rd_rid = field_tex[cur]


# ---------------- game loop ----------------

func start_wave(amp: float, dur: float) -> void:
	if wave_t >= 0.0:
		_msg("海浪还在路上!")
		return
	wave_count += 1
	wave_amp = amp
	wave_dur = dur
	wave_t = 0.0
	_msg("第 %d 波海浪来了!浪高 %d cm" % [wave_count, int(amp * 100)])


func _next_wave_params() -> Array:
	return [minf(0.16 + 0.06 * (wave_count + 1), 1.0), 2.2 + 0.12 * minf(wave_count + 1, 10.0)]


func _process(delta: float) -> void:
	if paused:
		return
	var dt := minf(delta, 0.033)
	sim_time += dt
	frame_count += 1

	if auto_waves and wave_t < 0.0:
		next_timer -= dt
		if next_timer <= 0.0:
			var p := _next_wave_params()
			start_wave(p[0], p[1])

	var surge := 0.025 * sin(sim_time * 1.6)
	if wave_t >= 0.0:
		wave_t += dt
		var ph := sin(PI * clampf(wave_t / wave_dur, 0.0, 1.0))
		surge += wave_amp * ph * ph
		if wave_t > wave_dur + 2.5:
			wave_t = -1.0
			if flag_cell.x < 0 or not flag_washed:
				survived += 1
			next_timer = maxf(8.0, 22.0 - wave_count * 1.2)

	if demo:
		_demo_tick()
	elif brushing and tool_idx < 4:
		_update_brush_from_mouse()
	for s in 2:
		_sim_step(dt * 0.5, surge)

	shadow_tick += 1
	if shadow_tick % 6 == 0:
		_refresh_shadow()
		_update_flag_state()
	if shadow_tick % 10 == 0:
		_update_hud()
	if msg_timer > 0.0:
		msg_timer -= dt
		if msg_timer <= 0.0:
			hud_msg.text = ""

	if shot_path != "" and frame_count == shot_frames:
		_take_shot()


func _refresh_shadow() -> void:
	var data := rd.texture_get_data(field_tex[cur], 0)
	shadow = Image.create_from_data(N, N, false, Image.FORMAT_RGBAF, data)
	# bucket delta readback
	var b := rd.buffer_get_data(bucket_buf)
	var delta := b.decode_s32(0)
	if delta != 0:
		bucket = maxf(0.0, bucket + float(delta) / 1000.0)
		var z := PackedByteArray()
		z.resize(8)
		rd.buffer_update(bucket_buf, 0, 8, z)
	if bucket <= 0.0 and brushing and tool_idx == 0:
		brushing = false
		_msg("沙子不够了,先⛏挖点沙!")


func _height_at(gx: float, gz: float) -> float:
	gx = clampf(gx, 0.0, N - 1.001)
	gz = clampf(gz, 0.0, N - 1.001)
	var x0 := int(gx)
	var z0 := int(gz)
	var fx := gx - x0
	var fz := gz - z0
	var a := shadow.get_pixel(x0, z0).r
	var b := shadow.get_pixel(mini(x0 + 1, N - 1), z0).r
	var c := shadow.get_pixel(x0, mini(z0 + 1, N - 1)).r
	var d := shadow.get_pixel(mini(x0 + 1, N - 1), mini(z0 + 1, N - 1)).r
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)


func _pick_ground(screen_pos: Vector2) -> Vector2:
	var o := cam.project_ray_origin(screen_pos)
	var d := cam.project_ray_normal(screen_pos)
	var last_t := 0.0
	var t := 1.0
	for i in 500:
		var pos := o + d * t
		var gx := pos.x + N * 0.5
		var gz := pos.z + N * 0.5
		if gx >= 0.0 and gx < N - 1 and gz >= 0.0 and gz < N - 1 and pos.y <= _height_at(gx, gz):
			var lo := last_t
			var hi := t
			for k in 8:
				var m := (lo + hi) * 0.5
				var mp := o + d * m
				if mp.y <= _height_at(mp.x + N * 0.5, mp.z + N * 0.5):
					hi = m
				else:
					lo = m
			var hp := o + d * hi
			return Vector2(hp.x + N * 0.5, hp.z + N * 0.5)
		if pos.y < -3.0:
			break
		last_t = t
		t += 0.8
	return Vector2(-1, -1)


func _update_brush_from_mouse() -> void:
	var hit := _pick_ground(get_viewport().get_mouse_position())
	if hit.x >= 0.0:
		brush_pos = hit
	else:
		brushing = false


# ---------------- flag ----------------

func _build_flag() -> void:
	flag_node = Node3D.new()
	var pole := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12
	cm.bottom_radius = 0.12
	cm.height = 5.6
	pole.mesh = cm
	pole.position.y = 2.8
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.42, 0.29, 0.18)
	pole.material_override = pm
	flag_node.add_child(pole)
	var cloth := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.8, 1.2, 0.08)
	cloth.mesh = bm
	cloth.position = Vector3(1.5, 4.9, 0.0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.88, 0.27, 0.18)
	cloth.material_override = fm
	flag_node.add_child(cloth)
	flag_node.visible = false
	add_child(flag_node)


func _plant_flag(gx: int, gz: int) -> void:
	var px := shadow.get_pixel(gx, gz)
	if px.g > 0.05:
		_msg("水里插不了旗")
		return
	flag_cell = Vector2i(gx, gz)
	flag_base_h = px.r
	flag_washed = false
	flag_node.visible = true
	flag_node.position = Vector3(gx - N * 0.5, px.r, gz - N * 0.5)
	_msg("🚩 旗子插好了,守住它!")


func _update_flag_state() -> void:
	if flag_cell.x < 0 or flag_washed:
		return
	var px := shadow.get_pixel(flag_cell.x, flag_cell.y)
	flag_node.position.y = px.r
	if px.g > 0.28:
		flag_washed = true
		flag_node.visible = false
		_msg("🚩 旗子被海浪冲走了……")
	elif px.r < flag_base_h - 0.55:
		flag_washed = true
		flag_node.visible = false
		_msg("🚩 旗子下的沙被掏空,倒了……")


# ---------------- input ----------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw += event.relative.x * 0.005
		pitch = clampf(pitch + event.relative.y * 0.004, 0.15, 1.25)
		_update_cam()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			dist = clampf(dist * 0.94, 40.0, 320.0)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			dist = clampf(dist * 1.06, 40.0, 320.0)
			_update_cam()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if tool_idx == 4:
					var hit := _pick_ground(event.position)
					if hit.x >= 0.0:
						_plant_flag(int(hit.x), int(hit.y))
				else:
					brushing = true
			else:
				brushing = false
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				paused = not paused
				_msg("⏸ 已暂停" if paused else "▶ 继续")
			KEY_N:
				var p := _next_wave_params()
				start_wave(p[0], p[1])
			KEY_BRACKETLEFT:
				brush_r = maxf(2.0, brush_r - 1.0)
			KEY_BRACKETRIGHT:
				brush_r = minf(12.0, brush_r + 1.0)
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				_set_tool(event.keycode - KEY_1)


func _set_tool(i: int) -> void:
	tool_idx = i
	for b in tool_buttons.size():
		tool_buttons[b].button_pressed = (b == i)


# ---------------- HUD ----------------

func _build_hud() -> void:
	var font := SystemFont.new()
	font.font_names = ["PingFang SC", "Heiti SC", "Arial Unicode MS"]
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := VBoxContainer.new()
	top.position = Vector2(12, 10)
	layer.add_child(top)

	hud_stats = Label.new()
	hud_stats.add_theme_font_override("font", font)
	hud_stats.add_theme_font_size_override("font_size", 17)
	hud_stats.add_theme_color_override("font_color", Color(0.05, 0.24, 0.33))
	top.add_child(hud_stats)

	var row := HBoxContainer.new()
	top.add_child(row)
	for i in TOOLS.size():
		var b := Button.new()
		b.text = TOOL_LABELS[i]
		b.toggle_mode = true
		b.add_theme_font_override("font", font)
		b.pressed.connect(_set_tool.bind(i))
		row.add_child(b)
		tool_buttons.append(b)
	tool_buttons[0].button_pressed = true
	var wave_btn := Button.new()
	wave_btn.text = "🌊 来一波!"
	wave_btn.add_theme_font_override("font", font)
	wave_btn.pressed.connect(func() -> void:
		var p := _next_wave_params()
		start_wave(p[0], p[1]))
	row.add_child(wave_btn)
	var reset_btn := Button.new()
	reset_btn.text = "🔄 重置"
	reset_btn.add_theme_font_override("font", font)
	reset_btn.pressed.connect(_reset)
	row.add_child(reset_btn)

	hud_msg = Label.new()
	hud_msg.add_theme_font_override("font", font)
	hud_msg.add_theme_font_size_override("font_size", 19)
	hud_msg.add_theme_color_override("font_color", Color(0.82, 0.35, 0.16))
	top.add_child(hud_msg)
	_update_hud()


func _msg(t: String) -> void:
	hud_msg.text = t
	msg_timer = 3.2


func _update_hud() -> void:
	var mx := 0.0
	for z in range(0, int(N * 0.7), 3):
		for x in range(0, N, 3):
			mx = maxf(mx, shadow.get_pixel(x, z).r)
	height_cm = maxi(0, int((mx - SEA) * 100.0))
	var next_s := "来袭中!" if wave_t >= 0.0 else ("%d s" % int(ceil(next_timer)) if auto_waves else "手动")
	hud_stats.text = "🌊 扛住海浪 %d 波   🪣 沙子 %d   ⛰ 最高点 %d cm   ⏳ 下一波 %s   笔刷 %d" \
		% [survived, int(bucket), height_cm, next_s, int(brush_r)]


func _reset() -> void:
	var img := _gen_field_image()
	shadow = img
	var data := img.get_data()
	var zero := PackedByteArray()
	zero.resize(N * N * 16)
	for i in 2:
		rd.texture_update(field_tex[i], 0, data)
	rd.texture_update(flux_tex, 0, zero)
	rd.texture_update(sflux_tex, 0, zero)
	bucket = 2800.0
	survived = 0
	wave_count = 0
	wave_t = -1.0
	next_timer = 25.0
	flag_cell = Vector2i(-1, -1)
	flag_node.visible = false
	_msg("沙滩重置好了,开工!")


# ---------------- demo script (headless regression) ----------------

func _demo_tick() -> void:
	var f := frame_count
	if f >= 15 and f <= 55:
		tool_idx = 0
		brushing = true
		brush_r = 6.0
		brush_pos = Vector2(76.0 + (f - 15) * 1.1, 80.0)
	elif f >= 60 and f <= 84:
		tool_idx = 1
		brushing = true
		brush_pos = Vector2(76.0 + (f - 60) * 1.8, 92.0)
	elif f == 90:
		brushing = false
		_plant_flag(96, 78)
	elif f == 100:
		start_wave(0.46, 2.5)


# ---------------- scene building ----------------

func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot_path)
	print("shot saved: ", shot_path, "  fps=", Engine.get_frames_per_second(),
		"  bucket=", int(bucket), "  survived=", survived,
		"  flag_washed=", flag_washed, "  height_cm=", height_cm)
	get_tree().quit()


func _exit_tree() -> void:
	if rd == null:
		return
	field_tex2d.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(func() -> void:
		for t in field_tex:
			rd.free_rid(t)
		rd.free_rid(flux_tex)
		rd.free_rid(sflux_tex)
		rd.free_rid(bucket_buf)
		rd.free_rid(shader_rid))


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(N, N)
	plane.subdivide_width = N * 2 - 2
	plane.subdivide_depth = N * 2 - 2
	var mat := ShaderMaterial.new()
	mat.shader = load("res://terrain.gdshader")
	mat.set_shader_parameter("field_tex", field_tex2d)
	mat.set_shader_parameter("sun_dir", sun_vec)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.extra_cull_margin = 16.0
	add_child(mi)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(N, N)
	plane.subdivide_width = N * 2 - 2
	plane.subdivide_depth = N * 2 - 2
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


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 35.0, 0.0)
	sun.light_energy = 1.0
	sun.light_color = Color(1.0, 0.96, 0.87)
	sun.shadow_enabled = true
	sun.light_angular_distance = 1.6
	sun.directional_shadow_max_distance = 320.0
	sun.shadow_blur = 1.6
	add_child(sun)
	sun_vec = sun.global_transform.basis.z
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
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 2.4
	env.ssao_intensity = 2.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.08
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.91, 0.96)
	env.fog_density = 0.0007
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
