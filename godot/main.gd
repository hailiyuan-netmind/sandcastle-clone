extends Node3D
# Sandcastle 3D, Godot vertical slice.
# GPU compute sim (water pipe model + sand repose/erosion) + sculpting tools + HUD.
# Headless verification:
#   godot --path godot -- --shot=/tmp/a.png --frames=420 --demo
# Interactive: left drag = tool, right drag = orbit, wheel = zoom, 1-5 tools,
#              [ ] brush size, N = wave, Space = pause.

const N := 384            # 模拟网格分辨率
const CELL := 0.5         # 每格世界尺寸
const WORLD := N * CELL   # 世界边长 192,与旧版一致
const SEA := 0.9
# ---- MPM 活跃区(世界坐标) ----
const ZPOOL := 32768
const ZMAXQ := 512
const ZGX := 192
const ZGY := 16
const ZGZ := 80
const ZCELL := 0.75
const ZORIGIN := Vector3(-72.0, 0.0, -18.0)
const ZDT := 1.0 / 240.0
const ZSUB := 4
const ZE_SAND := 8000.0
const ZE_WATER := 2500.0
const ZGRAV := 25.0
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
# MPM 活跃区资源
var zshader: RID
var zpipeline: RID
var zpbuf: RID
var zgrid: RID
var spawn_buf: RID
var dep_tex: RID
var zpos_tex: RID
var zuset: RID
var zpos_tex2d: Texture2DRD

var shadow: Image                 # low-rate CPU copy for picking / flag / stats
var shadow_tick := 0

var sim_time := 0.0
var paused := false
var sea_level := SEA          # 涨潮:每波过后上升
var wave_t := -1.0
var wave_amp := 0.0
var wave_dur := 0.0
var wave_count := 0
var next_timer := 25.0
var auto_waves := true
var survived := 0
var bucket := 2800.0
var height_cm := 0
var surge_now := 0.0          # 供音效使用的当前浪涌强度
var game_over := false

var tool_idx := 0
var brush_r := 12.0        # 网格单位(0.5 世界单位/格)
var brushing := false
var brush_pos := Vector2.ZERO

var flag_node: Node3D
var flag_cell := Vector2i(-1, -1)
var flag_base_h := 0.0
var flag_washed := false
var dbg_max_water := 0.0

var cam_pivot: Node3D
var cam: Camera3D
var yaw := 0.34
var pitch := 0.38
var dist := 112.0
var sun_vec := Vector3(0.45, 0.62, 0.34)

var hud_stats: Label
var hud_msg: Label
var msg_timer := 0.0
var tool_buttons := []
var ui_font: SystemFont
var go_panel: Control
var go_stats: Label
var audio_pb: AudioStreamGeneratorPlayback
var audio_lp := 0.0
var brush_env := 0.0

var shot_path := ""
var shot_frames := 90
var record_dir := ""
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
		elif a.begins_with("--record="):
			record_dir = a.substr(9)
			DirAccess.make_dir_recursive_absolute(record_dir)
	_build_environment()
	_build_camera()
	var img := _gen_field_image()
	shadow = img
	_init_compute(img)
	_init_mpm_zone()
	_build_terrain()
	_build_water()
	_build_zone_particles()
	_build_flag()
	_build_hud()
	_build_audio()


# ---------------- field / compute ----------------

func _gen_field_image() -> Image:
	var img := Image.create(N, N, false, Image.FORMAT_RGBAF)
	for z in N:
		var t := float(z) / float(N)
		for x in N:
			var h := 1.55 - 1.35 * smoothstep(0.0, 1.0, clampf((t - 0.18) / 0.55, 0.0, 1.0))
			h += 0.05 * sin(x * 0.055) + 0.04 * sin(x * 0.025 + z * 0.035) + 0.02 * sin(z * 0.115)
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

	# 生成队列 + 沉积图(sim 与 MPM 两条管线共享)
	var sq := PackedByteArray()
	sq.resize(16 + ZMAXQ * 2 * 16)
	spawn_buf = rd.storage_buffer_create(sq.size(), sq)
	var dfmt := RDTextureFormat.new()
	dfmt.width = N
	dfmt.height = N
	dfmt.format = RenderingDevice.DATA_FORMAT_R32_SINT
	dfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var dz := PackedByteArray()
	dz.resize(N * N * 4)
	dep_tex = rd.texture_create(dfmt, RDTextureView.new(), [dz])

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
		var usq := RDUniform.new()
		usq.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		usq.binding = 5
		usq.add_id(spawn_buf)
		us.append(usq)
		var ud := RDUniform.new()
		ud.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		ud.binding = 6
		ud.add_id(dep_tex)
		us.append(ud)
		uniform_sets.append(rd.uniform_set_create(us, shader_rid, 0))

	field_tex2d = Texture2DRD.new()
	field_tex2d.texture_rd_rid = field_tex[0]


func _init_mpm_zone() -> void:
	var src := load("res://mpm_zone.glsl") as RDShaderFile
	zshader = rd.shader_create_from_spirv(src.get_spirv())
	zpipeline = rd.compute_pipeline_create(zshader)

	var pf := PackedFloat32Array()
	pf.resize(ZPOOL * 32)
	for i in ZPOOL:
		pf[i * 32 + 1] = -1000.0   # y
		pf[i * 32 + 3] = -1.0      # mat = inactive
	zpbuf = rd.storage_buffer_create(ZPOOL * 128, pf.to_byte_array())
	var gz := PackedByteArray()
	gz.resize(ZGX * ZGY * ZGZ * 16)
	zgrid = rd.storage_buffer_create(gz.size(), gz)

	var fmt := RDTextureFormat.new()
	fmt.width = 256
	fmt.height = ZPOOL / 256
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		+ RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zt := PackedByteArray()
	zt.resize(fmt.width * fmt.height * 16)
	zpos_tex = rd.texture_create(fmt, RDTextureView.new(), [zt])
	zpos_tex2d = Texture2DRD.new()
	zpos_tex2d.texture_rd_rid = zpos_tex

	var ids := [zpbuf, zgrid, spawn_buf, dep_tex, field_tex[0], field_tex[1], zpos_tex]
	var types := [
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, RenderingDevice.UNIFORM_TYPE_IMAGE,
		RenderingDevice.UNIFORM_TYPE_IMAGE, RenderingDevice.UNIFORM_TYPE_IMAGE,
		RenderingDevice.UNIFORM_TYPE_IMAGE,
	]
	var us := []
	for b in ids.size():
		var u := RDUniform.new()
		u.uniform_type = types[b]
		u.binding = b
		u.add_id(ids[b])
		us.append(u)
	zuset = rd.uniform_set_create(us, zshader, 0)


func _zparams(mode: int) -> PackedByteArray:
	var f := PackedFloat32Array([
		ZDT, ZGRAV, float(mode), float(ZPOOL),
		float(ZGX), float(ZGY), float(ZGZ), ZCELL,
		ZORIGIN.x, ZORIGIN.y, ZORIGIN.z, float(cur),
		ZE_SAND, ZE_WATER, float(ZMAXQ), float(N),
	])
	return f.to_byte_array()


func _params(dt: float, surge: float, damp: float, mode: int, tool: int) -> PackedByteArray:
	var f := PackedFloat32Array([
		dt, sea_level, surge, damp,
		float(mode), float(N), float(tool), CELL * CELL,
		brush_pos.x, brush_pos.y, brush_r, 9.0 if mode == 3 else sim_time,
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


func _zone_step() -> void:
	var cell_groups := (ZGX * ZGY * ZGZ + 63) / 64
	var part_groups := (ZPOOL + 63) / 64
	var spawn_groups := (ZMAXQ + 63) / 64
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, zpipeline)
	rd.compute_list_bind_uniform_set(cl, zuset, 0)
	var pc := _zparams(1)   # 消费生成队列
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, spawn_groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	for s in ZSUB:
		pc = _zparams(0)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, cell_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
		pc = _zparams(2)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, part_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
		pc = _zparams(3)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, cell_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
		pc = _zparams(4)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, part_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	rd.compute_list_end()


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
			sea_level = minf(1.32, sea_level + 0.018)   # 涨潮
			next_timer = maxf(8.0, 22.0 - wave_count * 1.2)
	surge_now = clampf(surge / 0.7, 0.0, 1.0)

	if demo:
		_demo_tick()
	elif brushing and tool_idx < 4:
		_update_brush_from_mouse()
	var zero4 := PackedByteArray()
	zero4.resize(4)
	rd.buffer_update(spawn_buf, 0, 4, zero4)   # 每帧清零生成计数(游标保留)
	for s in 2:
		_sim_step(dt * 0.5, surge)
	_zone_step()

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
	_fill_audio()

	if record_dir != "":
		if frame_count % 3 == 0 and frame_count <= shot_frames:
			var img := get_viewport().get_texture().get_image()
			img.save_png(record_dir + "/r%04d.png" % frame_count)
		if frame_count > shot_frames:
			print("recording done: ", record_dir)
			get_tree().quit()
	elif shot_path != "" and frame_count == shot_frames:
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


func _to_grid(pos: Vector3) -> Vector2:
	return Vector2((pos.x + WORLD * 0.5) / CELL, (pos.z + WORLD * 0.5) / CELL)


func _pick_ground(screen_pos: Vector2) -> Vector2:
	var o := cam.project_ray_origin(screen_pos)
	var d := cam.project_ray_normal(screen_pos)
	var last_t := 0.0
	var t := 1.0
	for i in 500:
		var pos := o + d * t
		var gp := _to_grid(pos)
		if gp.x >= 0.0 and gp.x < N - 1 and gp.y >= 0.0 and gp.y < N - 1 and pos.y <= _height_at(gp.x, gp.y):
			var lo := last_t
			var hi := t
			for k in 8:
				var m := (lo + hi) * 0.5
				var mp := o + d * m
				var mg := _to_grid(mp)
				if mp.y <= _height_at(mg.x, mg.y):
					hi = m
				else:
					lo = m
			return _to_grid(o + d * hi)
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

func _build_zone_particles() -> void:
	var verts := PackedVector3Array()
	verts.resize(ZPOOL)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://zone_particles.gdshader")
	mat.set_shader_parameter("pos_tex", zpos_tex2d)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.extra_cull_margin = 256.0
	add_child(mi)


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
	flag_node.position = Vector3(gx * CELL - WORLD * 0.5, px.r, gz * CELL - WORLD * 0.5)
	_msg("🚩 旗子插好了,守住它!")


func _update_flag_state() -> void:
	if flag_cell.x < 0 or flag_washed:
		return
	var px := shadow.get_pixel(flag_cell.x, flag_cell.y)
	flag_node.position.y = px.r
	var wmax := 0.0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var sx := clampi(flag_cell.x + dx, 0, N - 1)
			var sz := clampi(flag_cell.y + dz, 0, N - 1)
			wmax = maxf(wmax, shadow.get_pixel(sx, sz).g)
	dbg_max_water = maxf(dbg_max_water, wmax)
	# 本格被淹,或邻域出现深水涌浪才算冲走;贴着自家护城河不判死
	if px.g > 0.12 or wmax > 0.30:
		flag_washed = true
		flag_node.visible = false
		_show_game_over("🚩 旗子被海浪冲走了……")
	elif px.r < flag_base_h - 0.55:
		flag_washed = true
		flag_node.visible = false
		_show_game_over("🚩 旗子下的沙被掏空,倒了……")


func _show_game_over(reason: String) -> void:
	if game_over:
		return
	game_over = true
	auto_waves = false
	go_stats.text = "%s\n\n守住海浪  %d 波\n最高沙堡  %d cm\n最终潮位  +%d cm" \
		% [reason, survived, height_cm, int((sea_level - SEA) * 100.0)]
	go_panel.visible = true


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
				brush_r = maxf(4.0, brush_r - 2.0)
			KEY_BRACKETRIGHT:
				brush_r = minf(24.0, brush_r + 2.0)
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
	ui_font = font
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

	# ---- Game Over 结算面板 ----
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.18, 0.26, 0.88)
	sb.corner_radius_top_left = 16
	sb.corner_radius_top_right = 16
	sb.corner_radius_bottom_left = 16
	sb.corner_radius_bottom_right = 16
	sb.content_margin_left = 36.0
	sb.content_margin_right = 36.0
	sb.content_margin_top = 26.0
	sb.content_margin_bottom = 26.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "🌊 沙堡陷落 🌊"
	title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.75))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	go_stats = Label.new()
	go_stats.add_theme_font_override("font", font)
	go_stats.add_theme_font_size_override("font_size", 20)
	go_stats.add_theme_color_override("font_color", Color(0.92, 0.96, 0.98))
	go_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(go_stats)
	var again := Button.new()
	again.text = "🔄 再来一局"
	again.add_theme_font_override("font", font)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(_reset)
	vb.add_child(again)
	go_panel = center
	go_panel.visible = false
	_update_hud()


func _msg(t: String) -> void:
	hud_msg.text = t
	msg_timer = 3.2


func _update_hud() -> void:
	var mx := 0.0
	for z in range(0, int(N * 0.7), 3):
		for x in range(0, N, 3):
			mx = maxf(mx, shadow.get_pixel(x, z).r)
	height_cm = maxi(0, int((mx - sea_level) * 100.0))
	var next_s := "来袭中!" if wave_t >= 0.0 else ("%d s" % int(ceil(next_timer)) if auto_waves else "手动")
	hud_stats.text = "🌊 扛住海浪 %d 波   🪣 沙子 %d   ⛰ 最高点 %d cm   🌡 潮位 +%d cm   ⏳ 下一波 %s   笔刷 %d" \
		% [survived, int(bucket), height_cm, int((sea_level - SEA) * 100.0), next_s, int(brush_r)]


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
	sea_level = SEA
	flag_cell = Vector2i(-1, -1)
	flag_washed = false
	flag_node.visible = false
	game_over = false
	auto_waves = true
	if go_panel:
		go_panel.visible = false
	_msg("沙滩重置好了,开工!")


# ---------------- demo script (headless regression) ----------------

func _demo_tick() -> void:
	var f := frame_count
	if f >= 15 and f <= 55:
		tool_idx = 0
		brushing = true
		brush_r = 12.0
		brush_pos = Vector2(152.0 + (f - 15) * 2.2, 160.0)
	elif f >= 60 and f <= 84:
		tool_idx = 1
		brushing = true
		brush_pos = Vector2(152.0 + (f - 60) * 3.6, 184.0)
	elif f == 90:
		brushing = false
		_plant_flag(192, 178)   # 故意插在墙前洼地,测试旗子被冲走的结算流程
	elif f == 100:
		start_wave(1.0, 2.8)


# ---------------- scene building ----------------

func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot_path)
	print("shot saved: ", shot_path, "  fps=", Engine.get_frames_per_second(),
		"  bucket=", int(bucket), "  survived=", survived,
		"  flag_washed=", flag_washed, "  height_cm=", height_cm,
		"  game_over=", game_over)
	if flag_cell.x >= 0:
		var px := shadow.get_pixel(flag_cell.x, flag_cell.y)
		print("flag cell=", flag_cell, " sand=", "%.2f" % px.r, " water=", "%.2f" % px.g,
			" max_water_seen=", "%.3f" % dbg_max_water)
	get_tree().quit()


func _exit_tree() -> void:
	if rd == null:
		return
	field_tex2d.texture_rd_rid = RID()
	zpos_tex2d.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(func() -> void:
		for t in field_tex:
			rd.free_rid(t)
		rd.free_rid(flux_tex)
		rd.free_rid(sflux_tex)
		rd.free_rid(bucket_buf)
		rd.free_rid(spawn_buf)
		rd.free_rid(dep_tex)
		rd.free_rid(zpbuf)
		rd.free_rid(zgrid)
		rd.free_rid(zpos_tex)
		rd.free_rid(zshader)
		rd.free_rid(shader_rid))


func _build_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(WORLD, WORLD)
	plane.subdivide_width = N - 2
	plane.subdivide_depth = N - 2
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
	plane.size = Vector2(WORLD, WORLD)
	plane.subdivide_width = N - 2
	plane.subdivide_depth = N - 2
	var mat := ShaderMaterial.new()
	mat.shader = load("res://water.gdshader")
	mat.set_shader_parameter("field_tex", field_tex2d)
	mat.set_shader_parameter("sun_dir", sun_vec)
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


func _build_audio() -> void:
	var player := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 22050.0
	gen.buffer_length = 0.2
	player.stream = gen
	player.volume_db = -8.0
	add_child(player)
	player.play()
	audio_pb = player.get_stream_playback()


func _fill_audio() -> void:
	# 程序化环境音:低通白噪声的海浪 + 高频沙沙声(挖/堆沙时)
	if audio_pb == null:
		return
	var n := audio_pb.get_frames_available()
	if n <= 0:
		return
	n = mini(n, 2048)
	var amp := 0.10 + surge_now * 0.55
	var cutoff := 0.035 + surge_now * 0.22
	var brush_target := 0.5 if (brushing and tool_idx < 2) else 0.0
	brush_env = lerpf(brush_env, brush_target, 0.12)
	for i in n:
		var w := randf() * 2.0 - 1.0
		audio_lp += cutoff * (w - audio_lp)
		var s := audio_lp * amp
		if brush_env > 0.01:
			s += (randf() * 2.0 - 1.0) * 0.22 * brush_env
		audio_pb.push_frame(Vector2(s, s))


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
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://sky.gdshader")
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
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
