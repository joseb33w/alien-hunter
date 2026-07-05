extends Node3D
## RPG STREAMING TEMPLATE — orchestration. Fetches a FETCHABLE world.json + quests.json
## (loose files served next to index.html, NOT packed in the .pck) + the asset manifest,
## wires the streaming systems, and keeps the player / combat / HUD PERSISTENT across area
## transitions. Areas + their .glb stream from R2 at runtime.
##
## EDITS COME FROM THE CHAT, not in-game: a chat edit is validated by qgcheck server-side
## and the new world.json is written back to R2. This template POLLS world.json and
## hot-reloads the live area when it changes (no re-export), so an open preview updates live.
##
## CHUNK MODE: when world.mode=="chunk" the one-resident ZONE streamer (SceneManager) is replaced
## by ChunkManager (resident 3x3 ring around the player). All chunk wiring is ADDITIVE + guarded
## by chunk_mode, so a non-chunk world behaves exactly as before.

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4

# Default drivable-car model when a world-level "vehicles" entry omits "model" (resolved via _norm).
const VEHICLE_MODEL := "props/kk_city/car_sedan.glb"

# Third-person orbit camera (SpringArm rig) — see _build_player/_process/_input.
const CAM_DIST := 8.5
const CAM_HEAD := 1.5
const CAM_PITCH_MIN := -1.30
const CAM_PITCH_MAX := 0.6     # Wave 2: was -0.18 — raised (~+34°) so the player can look ABOVE the
                               # horizon. The SpringArm still pulls the cam off the ground on the way up.
const LOOK_SENS := 0.006

# Wave 2 (FEEL): canonical vertical motion + swim. GRAVITY applies ONLY while airborne — a floor snap
# hugs descents so the player never hovers off a ledge; together they restore the full default 45°
# climbable slope (stairs ~35° and river banks ~41° become walkable). SWIM floats the body at the
# water surface (head/shoulders above, always visible) when the water is deeper than a wade.
const GRAVITY := 22.0
const STEP_MAX := 1.2             # step-up assist lifts onto a lip no higher than this (else = a wall)
const SWIM_SPEED := 3.5
const SWIM_SURFACE_OFF := 0.4     # body floats this far below the water level -> head/shoulders above
const WADE_DEPTH := 1.1           # water depth (level - ground) beyond which walking becomes swimming
const CLIMB_SPEED := 3.0          # CONTRACT C: ladder ascent/descent speed along Y

# Wave 4 ranged fire: auto-aim cone APEX angle (i.e. ±15° of the character's facing) and the
# muzzle's forward offset from the GEquipSlot (approximates the weapon tip for flash + spawn).
const FIRE_CONE_DEG := 30.0
const MUZZLE_FWD := 0.4

# Wave 1.5 native hero_model: the placeholder capsule mesh is 1.6 tall centred at y=0.85, so its
# top sits ~1.65 m — a fetched hero avatar scales to that height before its feet are seated at y=0.
const HERO_HEIGHT := 1.65

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"   # overridden from window.location on web
var build_id := ""
var props_pool: Array = []

var world_data := {}
var quests_data := {}
var _world_raw := ""          # last raw world.json text (change-detect for the poll)
var _polling := false

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var _capsule_body: MeshInstance3D = null   # placeholder capsule mesh — hidden when a native hero_model attaches
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.0
var cam_pitch := -0.55
var look_idx := -1
var look_last := Vector2.ZERO
var swing_t := 0.0                 # melee swing window (visual + re-tap gate) — decays in _process
# Wave 4 equipped-weapon state. GEquip owns the attached visual; main tracks the "GEquipSlot"
# node it hangs on the player (the swing pivot AND the ranged muzzle origin) and keeps the
# visual in sync with rpg.equipped_weapon (_sync_equip_visual).
var weapon_slot: Node3D = null     # the GEquipSlot on the player (BoneAttachment3D or fixed offset)
var _equipped_visual_id := ""      # weapon id the attached visual represents (sync guard)
var _equip_busy := false           # _sync_equip_visual re-entrancy latch (its model fetch awaits)
var _fire_cd := 0.0                # ranged/thrown cooldown (1.0 / def rate) — decays in _process
var _weapon_stowed := false        # Wave 1.5: weapon visual hidden while DRIVING A VEHICLE (kept on mounts)

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem
var weather: Weather3D

# --- chunk-mode resident-ring streaming (behind world.mode=="chunk") ---
var chunk_manager: ChunkManager
var chunk_mode := false

# --- drivable vehicles (world-level "vehicles", vehicle.gd) — PERSISTENT, never cell-parented ---
var vehicle_root: Node3D = null   # persistent layer: chunk eviction / zone transitions never touch it
var vehicles: Array = []          # live Vehicle nodes
var active_vehicle: Vehicle = null   # the car being driven (input routed here; null = on foot)
var _vehicles_spec: Array = []    # snapshot of world "vehicles" for the hot-reload diff
var auto_roam := false          # ?soak=1 -> player auto-roams so peak memory can be measured headlessly
var _roam_t := 0.0
var _js_set_time_cb = null      # window.gogiSetTime callback (web) — held so JavaScriptBridge doesn't GC it
var _js_get_player_cb = null    # window.gogiGetPlayer callback (web, verify) — held so it isn't GC'd
var _js_solids_cb = null        # window.gogiSolids callback (web, verify) — held so it isn't GC'd

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

# Wave 2 FEEL state.
var swimming := false          # true while the player floats in deep water (see _chunk_physics)
var climbing = null            # CONTRACT C ladder state Dictionary {pos, base_y, top_y, facing}; null = off-ladder

var hud_layer: CanvasLayer
var stats: Label
var hp_bar: ColorRect

# --- XENOREACH systems ---
var species: SpeciesSystem
var save_sys: SaveSystem
var inv_ui: InventoryUI
var play_mode := "explore"          # "explore" | "missions" (title-screen choice)
var title_layer: CanvasLayer = null
var nav_root: Control = null        # objective nav aid (arrow + distance) — missions mode
var nav_arrow: Polygon2D = null
var nav_label: Label = null
var ally_btn: Button = null         # contextual ALLY button near a hostile species elder
var _ally_target := ""              # species id the ally button targets
var damage_vignette: ColorRect = null
var _hero_ap: AnimationPlayer = null   # hero locomotion clips (idle/walk/run)
var _hero_idle := ""
var _hero_walk := ""
var _hero_run := ""
var _hero_cur := ""
var _ally_scan_t := 0.0


func _ready() -> void:
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		var bid = JavaScriptBridge.eval("location.pathname.split('/').filter(Boolean)[0] || ''", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)
		var soak = JavaScriptBridge.eval("window.location.search.indexOf('soak=1')>=0", true)
		if typeof(soak) == TYPE_BOOL and soak:
			auto_roam = true

	_build_env()
	GSurf.set_palette(Color(0.88, 1.02, 1.06))   # cool alien grade across every built surface
	_build_player()
	_build_motes()
	# Prompt-driven sky + weather owns the env/sun from here; defaults to clear day
	# until world.json's "sky" block is read in _boot. (See _apply_weather.)
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_setup_web_time_hooks()   # window.gogiSetTime / gogiGetTime (web only) — needs `weather` to exist
	_build_hud()

	rpg = RpgState.new()
	add_child(rpg)
	rpg.changed.connect(_update_stats)
	rpg.changed.connect(_on_rpg_changed)   # Wave 4: chest auto-equip -> swap the weapon visual

	species = SpeciesSystem.new()
	add_child(species)
	species.setup(rpg)

	inv_ui = InventoryUI.new()
	add_child(inv_ui)
	inv_ui.setup(hud_layer, rpg, species)

	_build_title_screen()   # the gesture gate (audio unlock) + the EXPLORE / MISSIONS choice

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_url   # lets _region_base_dir() resolve region_*.json next to world.json
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)
	quest.objective_changed.connect(_update_stats)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	interaction.main_ref = self   # Wave 3: _nearest reads active_vehicle so seats are gated while driving/riding
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)   # reach_area objectives progress on arrival

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)   # chunk-mode reach_area parity (only the active streamer emits)

	# poll world.json so a chat edit (qgcheck-gated, written to R2) hot-reloads live
	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	# Wave 4: attach the default melee weapon NOW (parametric — no fetch), replacing the old
	# hardcoded sword MeshInstance, so the player isn't bare-handed while world.json streams.
	# _boot re-syncs if "start_weapon" names something else.
	_sync_equip_visual()

	_update_stats()
	_boot()


func _boot() -> void:
	# manifest -> props pool (best effort)
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	# world.json (required) — a loose file served next to index.html.
	# --local-world (headless verify hook): read the project-local copy instead of HTTP.
	var raw := ""
	if "--local-world" in OS.get_cmdline_user_args():
		var lf := FileAccess.open("res://world.json", FileAccess.READ)
		if lf != null:
			raw = lf.get_as_text()
	else:
		var wq := HTTPRequest.new()
		add_child(wq)
		wq.request(world_url)
		var wr = await wq.request_completed
		wq.queue_free()
		if wr[1] != 200:
			stats.text = "world.json fetch failed (HTTP %s) @ %s" % [str(wr[1]), world_url]
			return
		raw = (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		stats.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw
	_apply_weather(world)
	rpg.load_weapons(world.get("weapons", {}))   # Wave 4: world "weapons" merge over inline ITEMS

	# quests.json (fetched alongside world.json — the same data qgcheck validates)
	var qraw := ""
	if "--local-world" in OS.get_cmdline_user_args():
		var qf := FileAccess.open("res://quests.json", FileAccess.READ)
		if qf != null:
			qraw = qf.get_as_text()
	else:
		var qq := HTTPRequest.new()
		add_child(qq)
		qq.request(world_url.replace("world.json", "quests.json"))
		var qr = await qq.request_completed
		qq.queue_free()
		if qr[1] == 200:
			qraw = (qr[3] as PackedByteArray).get_string_from_utf8()
	if qraw != "":
		var qdata = JSON.parse_string(qraw)
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			# NOT auto-started here: the title screen's MISSIONS choice starts the chain
			# (EXPLORE leaves the world free-roam; a restored save keeps its own progress)

	# world-level drivable vehicles — spawned ONCE onto the persistent layer BEFORE the streamer
	# starts, so their builder._ensure can't interleave with a cell build's parallel downloads.
	await _spawn_vehicles(world)

	# Wave 4: "start_weapon" equips at spawn. Its model prefetch is SERIALIZED here (like the
	# vehicles above) so a library//BUILD_ID weapon GLB can't interleave with the streamer's
	# parallel downloads; "parametric:*" models need no fetch at all.
	var start_id := String(world.get("start_weapon", ""))
	if start_id != "":
		if not rpg.has_item(start_id):
			rpg.add_item(start_id)
		rpg.equip(start_id, true)   # force: the authored start weapon wins regardless of damage
	await _sync_equip_visual()

	# Wave 1.5: a world-level "hero_model" wears a real character over the placeholder capsule.
	# Serialized here (like the vehicles/start_weapon prefetch) so its GLB fetch can't interleave
	# with the streamer's parallel downloads.
	await _attach_hero_model()

	if String(world.get("mode", "")) == "chunk":
		chunk_mode = true
		scene_manager._fade.visible = false   # chunk mode never fades -> hide the opaque black overlay
		sun.shadow_enabled = true              # restored: the floor slab is cast_shadow=OFF (no self-acne),
		sun.shadow_normal_bias = 2.0           # so props/buildings cast real contact shadows + read as planted
		sun.directional_shadow_max_distance = 42.0   # ring is only ~24u -> tight cascade = sharper + cheaper (mobile)
		await chunk_manager.start(world)
		_wire_vehicle_terrain()   # GTerrain exists only after start() — hand it to the parked cars
		# Wave 3 spawn-clearance: vehicles spawn (line ~235) BEFORE any cell is built, so a vehicle
		# authored on top of a building can't be de-wedged at spawn time — do it now that the start
		# ring's structures exist. Pushes only a genuinely-wedged vehicle onto clear ground.
		for v in vehicles:
			if is_instance_valid(v):
				v.global_position = chunk_manager.nudge_out(v.global_position, 2.5)
		interaction.terrain = chunk_manager.terrain   # Wave 3: grounds the stand-up-from-a-seat spot
	else:
		scene_manager.start(world)

	# signature hunter gear: the wrist blade is start_weapon; the plasma caster comes along too
	if not rpg.has_item("plasma_caster") and rpg.weapons.has("plasma_caster"):
		rpg.add_item("plasma_caster")

	_wire_hero_locomotion()

	# Supabase persistence: restore the previous run (inventory / quests / alliances / position)
	save_sys = SaveSystem.new()
	add_child(save_sys)
	save_sys.setup(self, rpg, quest, species)
	var saved: Dictionary = await save_sys.load_state()
	if not saved.is_empty():
		save_sys.apply_state(saved)
		_equipped_visual_id = ""
		await _sync_equip_visual()
		var sp = save_sys.saved_position()
		if sp != null and chunk_mode:
			player.global_position = sp
		print("GOGI_SAVE restored")

	print("GOGI_BOOT_COMPLETE")
	if "--logic-test" in OS.get_cmdline_user_args():
		var ts = load("res://logic_test.gd")
		if ts != null:
			add_child((ts as GDScript).new())


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if active_vehicle != null:
		# DRIVING: feed the car the SAME input vector that walks the player (one input path, no
		# second binding). The vehicle integrates it in its own physics tick and parks the hidden
		# player on itself, so chunk streaming + reach_area quest notifications (both read
		# player.global_position) keep following the driven position.
		if not is_instance_valid(active_vehicle):
			active_vehicle = null   # freed under us (hot-reload edge) — fall through to on-foot
		else:
			# CONTRACT A: feed the vehicle a CAMERA-relative world-XZ desired heading (length =
			# throttle 0..1). The raw drive_input(Vector2) path stays intact on vehicle.gd for the
			# verify harness — we just route the on-screen drive through drive_input_world here.
			var v := _keyboard_vec() + move_vec
			if v.length() > 1.0:
				v = v.normalized()
			var d3 := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
			# Untyped hop: this compiles green while vehicle.gd's drive_input_world half lands in
			# parallel (a typed Vehicle call would parse-fail until the method exists).
			var av = active_vehicle
			av.drive_input_world(Vector2(d3.x, d3.z))
			return
	# Wave 3 (sittable furniture): a SEATED player doesn't move — but movement input IS the intent
	# to leave, so it stands them up first (interaction restores the pose + places them beside the
	# seat, grounded); motion resumes next tick. This ONE gate covers BOTH the zone and chunk
	# physics paths below. The camera is untouched — the SpringArm rig follows the seated player.
	if interaction != null and interaction.player_seated:
		if (_keyboard_vec() + move_vec).length() > 0.1:
			interaction.stand_player()
		return
	if chunk_mode:
		_chunk_physics(delta)
		return
	if scene_manager == null:
		return
	if scene_manager.transitioning or scene_manager.current_root == null:
		return
	var v := _keyboard_vec() + move_vec
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative: forward = away from the camera, rotated by the orbit yaw.
	var dir := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	# Wave 2 canonical vertical motion: horizontal drive + airborne-only gravity + floor snap, so
	# descents hug the ground (no ledge hover) and the full 45° slope stays climbable (stairs/ramps).
	player.velocity.x = dir.x * 6.0
	player.velocity.z = dir.z * 6.0
	if player.is_on_floor():
		player.velocity.y = 0.0
	else:
		player.velocity.y -= GRAVITY * delta
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_step_up_assist(dir)


func _chunk_physics(delta: float) -> void:
	# FALL-CATCHER: if the body ever ends up far below any possible ground (a cell not yet
	# built under a fast-moving player on a slow device), reseat it on the terrain instead
	# of falling forever into the void.
	if player.global_position.y < -30.0 and chunk_manager != null:
		var p := player.global_position
		p.y = chunk_manager._ground_y(p.x, p.z) + 1.5
		player.global_position = p
		player.velocity = Vector3.ZERO
	# CONTRACT C: a ladder takes over vertical motion entirely (the ONE no-vertical-face exception).
	if climbing != null:
		_climb_physics(delta)
		return
	var v := _keyboard_vec() + move_vec
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		# diagonal ping-pong across the whole grid -> the resident ring shifts + evicts repeatedly
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(
			Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative when the player drives; world-relative during the headless
	# soak roam (auto_roam computes a world-space target, cam_yaw must not rotate it).
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)

	# CONTRACT D: swim/wade is decided from chunk_manager's water fields (READ-only). `depth` is how
	# far the water level sits above the ground beneath the player's feet.
	var px := player.global_position.x
	var pz := player.global_position.z
	var wl := chunk_manager.water_level if (chunk_manager != null and chunk_manager.water_cfg != null) else -1e9
	var gy := chunk_manager._ground_y(px, pz) if chunk_manager != null else 0.0
	var depth := wl - gy
	if not swimming and depth > WADE_DEPTH and player.global_position.y < wl - 0.2:
		_enter_swim()
	elif swimming and depth <= WADE_DEPTH:
		_exit_swim()   # ground rose enough to wade out -> hand back to walk

	if swimming:
		# Float the body at the surface (head/shoulders above, always VISIBLE), move horizontally,
		# NO gravity — the water holds the player up.
		player.velocity.x = dir.x * SWIM_SPEED
		player.velocity.z = dir.z * SWIM_SPEED
		player.velocity.y = 0.0
		if dir.length() > 0.1:
			var slook := player.global_position - dir
			player.look_at(Vector3(slook.x, player.global_position.y, slook.z), Vector3.UP)
		player.move_and_slide()
		player.global_position.y = wl - SWIM_SURFACE_OFF   # pin to the surface after the slide
		return

	# WALK: horizontal drive at 6 m/s + airborne-only gravity + floor snap (canonical vertical
	# motion — hugs descents, restores the full 45° climbable slope, no mid-air ledge hover).
	player.velocity.x = dir.x * 6.0
	player.velocity.z = dir.z * 6.0
	if player.is_on_floor():
		# is_on_floor() goes STALE when the body underfoot despawns while we're motionless
		# (e.g. killing an enemy you stand on) — probe for real ground before trusting it.
		if dir.length() < 0.05 and not _ground_under_player():
			player.velocity.y = -1.0   # kick the fall; real gravity takes over next tick
		else:
			player.velocity.y = 0.0
	else:
		player.velocity.y -= GRAVITY * delta
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	_step_up_assist(dir)


# TRUE-ground probe under the player's feet (world OR enemy layer) — backs up is_on_floor()
# when it can go stale (see the walk branch above).
func _ground_under_player() -> bool:
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		player.global_position + Vector3(0, 0.2, 0),
		player.global_position - Vector3(0, 0.8, 0), L_WORLD | L_ENEMY)
	q.exclude = [player.get_rid()]
	return not space.intersect_ray(q).is_empty()


# CONTRACT C (player half): joystick-Y climbs Y between base_y/top_y at CLIMB_SPEED, pinned to the
# ladder xz so the player can't drift off; at the top step FORWARD onto the surface and detach; below
# the base or a strong sideways push also detaches. velocity.y drives motion — the one place a
# vertical face is walkable. `climbing` is the Dictionary interaction.gd's ladder USE handed us.
func _climb_physics(_delta: float) -> void:
	var c: Dictionary = climbing
	var pos: Vector3 = c["pos"]
	var base_y := float(c["base_y"])
	var top_y := float(c["top_y"])
	var facing: Vector3 = c["facing"]
	var v := _keyboard_vec() + move_vec
	if absf(v.x) > 0.7:
		climbing = null                      # strong sideways input -> step off the ladder
		return
	player.velocity = Vector3(0.0, -v.y * CLIMB_SPEED, 0.0)   # screen-up (-y) ascends
	player.move_and_slide()
	player.global_position.x = pos.x         # pin to the ladder xz (no drift)
	player.global_position.z = pos.z
	if player.global_position.y >= top_y:
		player.global_position.y = top_y
		player.global_position += facing.normalized() * 0.6   # step forward onto the top surface
		climbing = null
		return
	if player.global_position.y <= base_y:
		player.global_position.y = base_y
		if v.y > 0.1:                        # still pushing down at the foot -> dismount at the base
			climbing = null


func _enter_swim() -> void:
	swimming = true
	GPose.swim(player)                       # self-guards: a capsule (unrigged) player is a no-op


func _exit_swim() -> void:
	swimming = false
	GPose.stand(player)


# Wave 2 UNIVERSAL STEP-UP ASSIST: when a grounded walk is blocked by a low lip (is_on_wall while
# pushing into it) but a walkable surface sits just ahead no higher than STEP_MAX, lift the feet onto
# it. This is the shoreline-exit + low-ledge fix. A DOWN-ray from just above STEP_MAX finds the
# surface; anything higher (a true wall) is left alone so the player is never launched up a face.
# Works in BOTH modes/tiers via the physics ray — no dependency on the terrain heightfield.
func _step_up_assist(dir: Vector3) -> void:
	if player == null or dir.length() < 0.1:
		return
	if not (player.is_on_wall() and player.is_on_floor()):
		return
	var into := dir.normalized()
	if into.dot(-player.get_wall_normal()) < 0.3:
		return                               # not actually moving into the wall we hit
	var feet := player.global_position.y
	# Probe PAST the capsule radius (0.4): at exactly the radius the down-ray lands tangent to a
	# sharp ledge face and hits the ground IN FRONT of it (step≈0) instead of the lip on top, so
	# low sharp ledges never lifted. 0.6 = radius + margin, landing the ray solidly on the lip.
	var ahead := player.global_position + into * 0.6
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(ahead.x, feet + STEP_MAX + 0.1, ahead.z),
		Vector3(ahead.x, feet - 0.5, ahead.z), L_WORLD)
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var step := float(hit["position"].y) - feet
	if step > 0.05 and step <= STEP_MAX:
		player.global_position.y = float(hit["position"].y) + 0.02   # onto the lip


func _process(delta: float) -> void:
	if cam_rig and player:
		# Rig follows the player; yaw/pitch come from drag-look. The SpringArm
		# keeps the camera aimed at the head and pulls it in through walls.
		var head := CAM_HEAD
		# HIDDEN driver (closed-cabin modeled vehicle / tank swap-in): the player is parked at
		# the body origin, so the head pivot sits INSIDE the hull — lift it so the orbit reads
		# over the roof. Keyed on visibility, not body type: any hidden-driver ride has this.
		if active_vehicle != null and is_instance_valid(active_vehicle) and not player.visible:
			head += 0.6
		# CONTRACT B: while driving AND not drag-looking, ease the orbit behind the vehicle. Manual
		# drag-look (look_idx != -1) overrides so the player keeps camera control. Composes with the
		# Wave 1.5 hidden-driver head-lift above (both keyed on active_vehicle).
		if active_vehicle != null and is_instance_valid(active_vehicle) and look_idx == -1:
			cam_yaw = lerp_angle(cam_yaw, active_vehicle.rotation.y + PI, minf(1.0, 3.0 * delta))
		cam_rig.global_position = player.global_position + Vector3(0.0, head, 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
	# Wave 4: attack timers + the melee swing visual moved HERE from the two physics paths
	# (which early-return while DRIVING) so a MOUNTED rider's swing still animates/decays and
	# the ranged cooldown keeps ticking — riders fire too. Same 0.22s window and the exact
	# hardcoded-sword formula, now routed at the GEquipSlot pivot. Non-melee weapons keep the
	# orientation GEquip gave them (no -10° idle stomp on a bow).
	swing_t = maxf(0.0, swing_t - delta)
	_fire_cd = maxf(0.0, _fire_cd - delta)
	if weapon_slot != null and is_instance_valid(weapon_slot) \
			and String(_equipped_def().get("kind", "melee")) == "melee":
		weapon_slot.rotation_degrees.x = (-90.0 + (1.0 - swing_t / 0.22) * 120.0) if swing_t > 0.0 else -10.0
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	_ally_scan_t -= delta
	if _ally_scan_t <= 0.0:
		_ally_scan_t = 0.3
		_scan_elders()
		_publish_state()
	_update_nav_aid()
	_update_hero_anim()
	if stats:
		_refresh_stats()


# ---------------- HUD ----------------

func _update_stats() -> void:
	_refresh_stats()
	if hp_bar and rpg:
		hp_bar.size.x = 320.0 * clamp(rpg.hp / rpg.max_hp, 0.0, 1.0)


func _refresh_stats() -> void:
	if rpg == null:
		return
	var streamer = chunk_manager if chunk_mode else scene_manager
	var alive := 0
	if streamer:
		for e in streamer.enemies:
			if is_instance_valid(e) and not e.dead:
				alive += 1
	var area: String = String(streamer.current_id) if streamer != null else ""
	var obj := quest.current_objective() if quest else ""
	stats.text = "Lv %d  HP %d/%d  XP %d/%d  Gold %d  Wpn:%s\nArea:%s  enemies %d  fps %d\nInv: %s\n%s" % [
		rpg.level, int(rpg.hp), int(rpg.max_hp), rpg.xp, rpg.xp_next, rpg.gold,
		rpg.item_name(rpg.equipped_weapon), area, alive, Engine.get_frames_per_second(),
		rpg.inventory_summary(), obj]


# ---------------- combat / hooks ----------------

# The ONE attack entry (the HUD ATTACK button): routes by the equipped weapon's kind.
# melee -> the Wave-1 swing, byte-identical semantics (2.6u reach, forward half-cone,
# enemy.take_hit). ranged/thrown -> _fire_ranged (auto-aim + pooled GProjectile). The button
# stays LIVE while DRIVING/MOUNTED — only _physics_process's movement routing is gated on
# active_vehicle, Button.pressed never passes through it — so riders fire too.
func _attack() -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null or streamer.transitioning:
		return
	var def := _equipped_def()
	var kind := String(def.get("kind", "melee"))
	if kind == "ranged" or kind == "thrown":
		_fire_ranged(def, streamer)
		return
	if swing_t > 0.0:
		return
	swing_t = 0.22
	AudioManager.play_sfx("attack")
	var dmg := rpg.weapon_damage()
	var fwd := -player.global_transform.basis.z
	for e in streamer.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = e.global_position - player.global_position
		to.y = 0.0
		if to.length() < 2.6 and fwd.dot(to.normalized()) > 0.25:
			e.take_hit(dmg)


# The live equipped-weapon def: GEquip stamps "gequip_def" on the character at equip time;
# before the first equip lands (async boot) fall back to the catalog def for the equipped id.
func _equipped_def() -> Dictionary:
	if player != null and player.has_meta("gequip_def"):
		var d = player.get_meta("gequip_def")
		if d is Dictionary:
			return d
	return rpg.weapon_def(rpg.equipped_weapon) if rpg != null else {}


# Wave 4 ranged/thrown fire — mobile-first AUTO-AIM: the NEAREST live enemy inside the
# FIRE_CONE_DEG cone of the character's facing AND inside weapon range is aimed at its chest
# (+1.0m); none in the cone -> straight ahead. The per-weapon rate gates repeat taps.
# MOUNTED riders compose for free: the GEquipSlot rides the player, which vehicle.gd's
# _track_driver parks (and faces) on the boardable every tick — origin + facing follow, no
# special casing. Facing is +basis.z, the stack convention (characters FACE +Z — see
# vehicle.gd / GPose); melee's legacy -basis.z half-cone above is untouched by contract.
func _fire_ranged(def: Dictionary, streamer) -> void:
	if _fire_cd > 0.0:
		return
	var root: Node3D = streamer.current_root
	if root == null or not is_instance_valid(root):
		return
	_fire_cd = 1.0 / maxf(0.1, float(def.get("rate", 1.2)))
	var fwd: Vector3 = player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.BACK
	var rng := maxf(1.0, float(def.get("range", 20.0)))
	var cone := cos(deg_to_rad(FIRE_CONE_DEG * 0.5))
	var best: Node3D = null
	var bd := rng   # nearest-wins inside the cone
	for e in streamer.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = (e as Node3D).global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > bd:
			continue
		if fwd.dot(to / d) < cone:
			continue
		bd = d
		best = e
	# muzzle = the GEquipSlot (weapon tip-ish) + a small forward offset; slot not attached
	# yet (async equip in flight) -> chest height on the player. in_tree guard: NEVER read a
	# global transform off a detached node (doctrine).
	var muzzle: Vector3 = player.global_position + Vector3(0.0, 1.2, 0.0)
	if weapon_slot != null and is_instance_valid(weapon_slot) and weapon_slot.is_inside_tree():
		muzzle = weapon_slot.global_position
	muzzle += fwd * MUZZLE_FWD
	var dir: Vector3 = fwd
	if best != null:
		dir = ((best.global_position + Vector3(0.0, 1.0, 0.0)) - muzzle).normalized()
	AudioManager.play_sfx("attack")
	GProjectile.flash(muzzle, root)
	GProjectile.fire(root, muzzle, dir, def, _live_enemies)


# enemies_provider handed to GProjectile.fire — always the ACTIVE streamer's live union
# (chunk resident ring / zone area), so a projectile in flight never holds a stale list.
func _live_enemies() -> Array:
	var streamer = chunk_manager if chunk_mode else scene_manager
	return streamer.enemies if streamer != null else []


# Keep the ATTACHED weapon visual in sync with rpg.equipped_weapon (boot start_weapon, chest
# auto-equip upgrades, hot-reload re-stats). "parametric:*" models attach with no fetch;
# library//BUILD_ID GLBs prefetch through the SHARED builder cache (the vehicles' path).
# Loops because equipped_weapon can change again during the await; GEquip.equip is
# idempotent, one weapon at a time.
func _sync_equip_visual() -> void:
	if _equip_busy or player == null or rpg == null:
		return
	_equip_busy = true
	while _equipped_visual_id != rpg.equipped_weapon:
		var id: String = rpg.equipped_weapon
		var def: Dictionary = rpg.weapon_def(id)
		var model: Node3D = null
		var mu := String(def.get("model", ""))
		if mu != "" and not mu.begins_with("parametric:"):
			var u := _norm(mu)
			if u != "":
				await builder._ensure([u])
				if builder.cache.has(u) and builder.cache[u] != null:
					model = (builder.cache[u] as Node).duplicate() as Node3D
		GEquip.equip(player, def, model)
		weapon_slot = player.find_child("GEquipSlot", true, false) as Node3D
		if weapon_slot != null:
			weapon_slot.visible = not _weapon_stowed   # a mid-ride re-equip must not un-stow (Wave 1.5)
		_equipped_visual_id = id
	_equip_busy = false


func _on_rpg_changed() -> void:
	if rpg != null and _equipped_visual_id != rpg.equipped_weapon:
		_sync_equip_visual()   # fire-and-forget — the latch + loop absorb re-entry


func take_damage(d: float) -> void:
	if d <= 0.0:
		return
	AudioManager.play_sfx("hurt")
	_shake_camera(minf(0.35, 0.08 + d * 0.01))
	_flash_vignette()
	if chunk_mode:
		if rpg.take_damage(d):
			rpg.hp = rpg.max_hp   # forgiving respawn in place (no area transition in chunk mode)
		return
	if scene_manager == null or scene_manager.transitioning:
		return
	if rpg.take_damage(d):
		rpg.hp = rpg.max_hp        # forgiving respawn: full heal in the current area
		scene_manager.goto_area(scene_manager.current_id, scene_manager.areas[scene_manager.current_id].spawns.keys()[0])


## Allied mylah companions mend the hunter. Returns true when any healing was applied.
func heal_player(amount: float) -> bool:
	if rpg == null or rpg.hp >= rpg.max_hp:
		return false
	rpg.hp = minf(rpg.max_hp, rpg.hp + amount)
	rpg.changed.emit()
	return true


func is_species_allied(id: String) -> bool:
	return species != null and species.is_allied(id)


func on_ally_betrayed(id: String) -> void:
	if species == null or not species.is_allied(id):
		return
	species.on_member_killed(id)
	interaction._show(["You struck an ally. The %s remember. HOSTILE again." % species.species_name(id)])


func live_enemy_list() -> Array:
	return _live_enemies()


func on_enemy_killed(type: String) -> void:   # called by enemy.gd on death
	AudioManager.play_sfx("death")
	if rpg:
		rpg.grant_xp(25 if type == "broodmaw" else 15)
		# the hunt pays: treasure shards + a species trophy off every kill
		rpg.add_gold(randi_range(4, 14))
		if species != null and species.is_species(type):
			rpg.add_item("trophy_" + type)
			species.on_member_killed(type)
	if quest:
		quest.notify_kill(type)
	if type == "broodmaw":
		rpg.set_flag("broodmaw_slain")
		_show_victory()
	if save_sys:
		save_sys.mark_dirty()


func _show_victory() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 205
	add_child(layer)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.05, 0.06, 0.85)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.offset_left = -260
	vb.offset_right = 260
	vb.offset_top = -140
	vb.add_theme_constant_override("separation", 16)
	layer.add_child(vb)
	var t := Label.new()
	t.text = "THE BROODMAW IS SLAIN"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 46)
	t.add_theme_color_override("font_color", Color(0.95, 0.45, 0.85))
	vb.add_child(t)
	var s := Label.new()
	s.text = "The apex hunt is complete. This world knows its master.\nKeep roaming - the wilds are yours."
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	s.add_theme_font_size_override("font_size", 24)
	vb.add_child(s)
	var b := Button.new()
	b.text = "  CONTINUE  "
	b.add_theme_font_size_override("font_size", 30)
	b.pressed.connect(layer.queue_free)
	vb.add_child(b)


# ---------------- live hot-reload from chat edits ----------------

func _poll_world() -> void:
	# re-fetch world.json; if a chat edit changed it (qgcheck already gated it server-side),
	# hot-reload the current area live. Cache-buster bypasses the edge cache.
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var w = JSON.parse_string(raw)
	if not (w is Dictionary):
		return
	# chunk worlds carry "cells"/"grid" (not "areas"); zone worlds carry "areas"
	if chunk_mode:
		if not w.has("cells"):
			return
	elif not w.has("areas"):
		return
	_world_raw = raw
	world_data = w
	_apply_weather(w)
	# Wave 4: a chat edit can re-stat "weapons" (damage/model/…). Reload the merged catalog and
	# re-attach the visual ONLY when the equipped def's content actually changed (deep ==).
	# Awaited so a weapon-model fetch is serialized BEFORE the streamer reload's downloads.
	var eq_before: Dictionary = rpg.weapon_def(rpg.equipped_weapon)
	rpg.load_weapons(w.get("weapons", {}))
	if rpg.weapon_def(rpg.equipped_weapon) != eq_before:
		_equipped_visual_id = ""
		await _sync_equip_visual()
	# vehicles-only rebuild when the world "vehicles" list changed (never touches the player or the
	# streamer). Awaited so its model fetch is serialized BEFORE the streamer reload's downloads.
	await _reload_vehicles(w)
	if chunk_mode:
		chunk_manager.reload(world_data)   # rebuild only CHANGED resident cells in place — no player move
	else:
		scene_manager.reload(world_data)   # no re-export — the live area rebuilds


# ---------------- drivable vehicles (world-level "vehicles", vehicle.gd) ----------------

# Spawn the world's "vehicles" ONCE onto a persistent layer (a direct child of main — chunk cell
# eviction and zone area frees can never reclaim it). Zone worlds get the same world-space
# placement. Models fetch through the SHARED builder cache (parallel, dedup'd); a world with no
# "vehicles" returns immediately — zero behavior change.
func _spawn_vehicles(world: Dictionary) -> void:
	var list = world.get("vehicles", [])
	if not (list is Array) or (list as Array).is_empty():
		_vehicles_spec = []
		return
	_vehicles_spec = (list as Array).duplicate(true)   # snapshot for the hot-reload diff
	if vehicle_root == null:
		vehicle_root = Node3D.new()
		add_child(vehicle_root)
	var urls: Array = []
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var u := _vehicle_model_url(spec)
		if u != "" and not urls.has(u):
			urls.append(u)
	await builder._ensure(urls)
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var pos = spec.get("pos", [])
		if not (pos is Array) or (pos as Array).size() < 2:
			continue
		var mu := _vehicle_model_url(spec)
		var model: Node3D = null
		if mu != "" and builder.cache.has(mu) and builder.cache[mu] != null:
			model = (builder.cache[mu] as Node).duplicate() as Node3D
		var car := Vehicle.new()
		car.player_ref = player
		car.setup(spec, model)   # scale-normalize (4m car) + AABB-ground + box collider + prompt
		vehicle_root.add_child(car)
		car.global_position = Vector3(float(pos[0]), 0.0, float(pos[1]))
		car.drive_state_changed.connect(_on_vehicle_drive_state)
		interaction.add_vehicle(car)   # same touch/USE mechanism chests/NPCs use -> enter/exit
		vehicles.append(car)


# world.json vehicle "model" (or url/asset) -> absolute URL. Defaults are
# PER-PROFILE (Wave 3): mounts resolve their pinned library creature
# (farm_Horse / farm_Cow / monster_Dragon via Vehicle.default_model_path);
# parametric profiles (car/tank/boat/plane) return "" — the Vehicle builds
# its own body, so prefetching the sedan for them would be wasted.
func _vehicle_model_url(spec: Dictionary) -> String:
	var u := String(spec.get("model", spec.get("url", spec.get("asset", ""))))
	if u == "":
		u = Vehicle.default_model_path(String(spec.get("profile", "car")))
	if u == "":
		return ""   # parametric profile with no explicit model — nothing to fetch
	return _norm(u)


# Hot-reload: the polled world.json changed — if (and only if) its "vehicles" list differs from the
# spawned snapshot, rebuild the vehicles alone. The player is untouched UNLESS they are driving a
# rebuilt car, in which case they step out first (a hidden player must never be left attached to a
# freed node).
func _reload_vehicles(w: Dictionary) -> void:
	var list = w.get("vehicles", [])
	if not (list is Array):
		list = []
	if (list as Array) == _vehicles_spec:   # deep == on nested Arrays/Dictionaries
		return
	if active_vehicle != null and is_instance_valid(active_vehicle):
		active_vehicle.exit()   # clears active_vehicle via _on_vehicle_drive_state
	active_vehicle = null
	for v in vehicles:
		if is_instance_valid(v):
			(v as Node).queue_free()
	vehicles = []
	interaction.remove_vehicles()
	await _spawn_vehicles(w)
	_wire_vehicle_terrain()


# Vehicles spawn before ChunkManager builds GTerrain — hand them the heightfield afterwards so a
# parked car snaps onto the rendered surface (no-op for flat/zone worlds: terrain stays null -> y=0).
func _wire_vehicle_terrain() -> void:
	if not chunk_mode or chunk_manager == null:
		return
	for v: Vehicle in vehicles:
		if is_instance_valid(v):
			v.set_terrain(chunk_manager.terrain)
			# Wave 3: boats ride the water surface — hand them the level when
			# the world opted into water (else they keep the terrain degrade).
			if chunk_manager.water_cfg != null:
				v.set_water(chunk_manager.water_level)


# Enter/exit bookkeeping: route input to the active car and exclude its body from the camera
# SpringArm sweep (the car is on the world layer the arm collides with — without the exclusion the
# arm hits the car's own box and jams the camera against the roof).
func _on_vehicle_drive_state(v: Vehicle, is_driving: bool) -> void:
	if is_driving:
		active_vehicle = v
		cam_spring.add_excluded_object(v.get_rid())
		_set_weapon_stowed(not v.is_mount())   # Wave 1.5: stow the weapon in VEHICLES, keep it on mounts
	else:
		if active_vehicle == v:
			active_vehicle = null
		cam_spring.remove_excluded_object(v.get_rid())
		_set_weapon_stowed(false)   # back on foot — the weapon reappears


# Weapon-visual STOW (Wave 1.5). While DRIVING A VEHICLE the equipped weapon is hidden (a driver
# isn't brandishing a blade); MOUNTS keep it — firing from the saddle is a Wave-4 feature. Toggled
# ONLY on the board/exit transitions above, and re-asserted by _sync_equip_visual so a mid-ride
# chest auto-equip re-attaches HIDDEN. The HUD (Wpn: label, ATTACK button) is untouched — combat
# still fires; only the on-body visual disappears while stowed.
func _set_weapon_stowed(stow: bool) -> void:
	_weapon_stowed = stow
	if weapon_slot != null and is_instance_valid(weapon_slot):
		weapon_slot.visible = not stow


# ---------------- input ----------------

func _input(event: InputEvent) -> void:
	if scene_manager == null or scene_manager.transitioning:
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < half and move_idx == -1:
				move_idx = event.index
				move_origin = event.position
				move_vec = Vector2.ZERO
			elif event.position.x >= half and look_idx == -1:
				# right half of the screen = drag to orbit the camera
				look_idx = event.index
				look_last = event.position
		else:
			if event.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif event.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		if event.index == move_idx:
			move_vec = ((event.position - move_origin) / 80.0).limit_length(1.0)
		elif event.index == look_idx:
			_apply_look(event.position - look_last)
			look_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and move_idx == -1 and look_idx == -1:
		# desktop drag-look (no active touches → ignores emulated-from-touch motion)
		_apply_look(event.relative)


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


# ---------------- manifest ----------------

func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		return
	# Scatter = ambient NATURE clutter ONLY (rocks/plants/trees/logs). The manifest tags every prop
	# with a `category`; pulling the WHOLE library scattered buildings/walls/swords/pipes into every
	# area (incongruous, odd-shaped "floating" junk). Named PALETTE props are a separate path, unaffected.
	for p in data.get("props", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("category", "")) != "nature":
			continue
		# within "nature", skip terrain/tiling pieces (cliffs, paths, beach/road edges) — those tile
		# the ground, they're not free-standing scatter clutter
		var fn := String(p.get("file", "")).get_file().to_lower()
		if "terrain" in fn or "path" in fn or "cliff" in fn or "beach" in fn or "railway" in fn or "road" in fn or "fence" in fn:
			continue
		var u := _norm(String(p.get("file", "")))   # relative → resolves against origin (portable)
		if u != "" and "/godot-assets/props/" in u:
			props_pool.append(u)


func _collect(v, out_arr: Array) -> void:
	match typeof(v):
		TYPE_STRING:
			if (v as String).to_lower().ends_with(".glb"):
				out_arr.append(v)
		TYPE_DICTIONARY:
			for k in v:
				_collect(v[k], out_arr)
		TYPE_ARRAY:
			for e in v:
				_collect(e, out_arr)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


# Prompt-driven sky/weather: the agent sets a top-level "sky" block in world.json
# (a fixed {time,weather} or a {cycle:[...],loop}). Re-applied on hot-reload.
func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


# ---------------- web time-of-day hooks (window.gogiSetTime / gogiGetTime) ----------------

# Let page JS drive the sky for preview/QA harnesses. gogiSetTime(state) pins the time-of-day
# INSTANTLY (Weather3D.set_time snaps — no lerp) keeping the current weather; gogiGetTime() reads
# the last-applied state back. Accepts any Weather3D TIME key ("day"/"night"/"sunrise"/"sunset").
# No-op off the web. The callback is stored in a member — JavaScriptBridge callbacks are GC'd the
# instant nothing references them.
func _setup_web_time_hooks() -> void:
	if not OS.has_feature("web") or weather == null:
		return
	_js_set_time_cb = JavaScriptBridge.create_callback(_on_gogi_set_time)
	var win = JavaScriptBridge.get_interface("window")
	if win != null:
		win.gogiSetTime = _js_set_time_cb
	JavaScriptBridge.eval("window.__gogiTime='%s';window.gogiGetTime=function(){return window.__gogiTime;};" % weather.time_state, true)
	# Wave 5: publish window.gogiGetPlayer() + window.gogiSolids() so verify.mjs's live probes (drive /
	# swim / collision / spawn / ascent / streaming) activate. Each raw callback returns a JSON STRING
	# (the only reliably-marshalled return type); a thin JS wrapper JSON.parses it to the object/array
	# the probes expect (verify.mjs:1255-1258). Web + verify only; no cost off the web.
	_js_get_player_cb = JavaScriptBridge.create_callback(_on_gogi_get_player)
	_js_solids_cb = JavaScriptBridge.create_callback(_on_gogi_solids)
	if win != null:
		win.__gogiGetPlayerRaw = _js_get_player_cb
		win.__gogiSolidsRaw = _js_solids_cb
	JavaScriptBridge.eval(
		"window.gogiGetPlayer=function(){var s=window.__gogiGetPlayerRaw();return s?JSON.parse(s):null;};" +
		"window.gogiSolids=function(){var s=window.__gogiSolidsRaw();return s?JSON.parse(s):[];};", true)


func _on_gogi_set_time(args: Array) -> void:
	if weather == null or args.is_empty():
		return
	var state := String(args[0])
	weather.set_time(state)   # immediate where the state resolves; a lerp only if a cycle chase is mid-flight
	JavaScriptBridge.eval("window.__gogiTime='%s';" % weather.time_state, true)
	print("GOGI_TIME ", weather.time_state)


# PUSH-based live-state publication (web only, ~3x/sec): JavaScriptBridge callbacks can't
# return values to page JS, so the pull-style __gogiGetPlayerRaw yields null in harnesses —
# instead we PUSH the state into window.__gogiPlayerState (+ solids, throttled) and
# gogiGetPlayer/gogiSolids read those. Powers the verify feel-probes; inert on device.
var _solids_pub_t := 0.0

func _publish_state() -> void:
	if not OS.has_feature("web") or player == null:
		return
	JavaScriptBridge.eval("window.__gogiPlayerState=%s;window.gogiGetPlayer=function(){return window.__gogiPlayerState||null};" % _on_gogi_get_player([]), true)
	_solids_pub_t -= 0.3
	if _solids_pub_t <= 0.0:
		_solids_pub_t = 3.0
		JavaScriptBridge.eval("window.__gogiSolidsData=%s;window.gogiSolids=function(){return window.__gogiSolidsData||[]};" % _on_gogi_solids([]), true)


# window.gogiGetPlayer() — live player state as a JSON string (the JS wrapper parses it). Fields match
# the verify.mjs probe contract (verify.mjs:1255-1258). Off-ladder `climbing` is null -> false.
func _on_gogi_get_player(_args: Array) -> String:
	if player == null or not is_instance_valid(player):
		return "null"
	var p := player.global_position
	var d := {
		"x": p.x, "y": p.y, "z": p.z,
		"in_vehicle": active_vehicle != null and is_instance_valid(active_vehicle),
		"cam_yaw": cam_yaw,
		"climbing": climbing != null,
		"swimming": swimming,
	}
	if active_vehicle != null and is_instance_valid(active_vehicle):
		d["vehicle_yaw"] = active_vehicle.rotation.y
	return JSON.stringify(d)


# window.gogiSolids() — world AABBs of the SOLID bodies (structures/props/roads) in the resident ring,
# as a JSON string of [{min:[x,y,z], max:[x,y,z]}]. Excludes the terrain floor (group "gogi_terrain")
# so a player standing ON the ground never reads as "inside a solid". On-demand only (verify probes).
func _on_gogi_solids(_args: Array) -> String:
	var out: Array = []
	if chunk_manager != null and is_instance_valid(chunk_manager):
		for k in chunk_manager.resident:
			var rec = chunk_manager.resident[k]
			var root = rec.get("root")
			if root != null and is_instance_valid(root):
				_collect_solids(root, out)
	return JSON.stringify(out)


func _collect_solids(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is StaticBody3D and not (c as Node).is_in_group("gogi_terrain"):
			var ab := _body_world_aabb(c as StaticBody3D)
			if ab.size.length() > 0.01:
				out.append({
					"min": [ab.position.x, ab.position.y, ab.position.z],
					"max": [ab.end.x, ab.end.y, ab.end.z]})
		_collect_solids(c, out)


# Merged world AABB of a static body's collision shapes. Shape3D.get_debug_mesh() yields a local AABB
# for ANY shape (box/sphere/trimesh), transformed by the shape node's world transform.
func _body_world_aabb(body: StaticBody3D) -> AABB:
	var merged := AABB()
	var first := true
	for cs in body.get_children():
		if cs is CollisionShape3D and (cs as CollisionShape3D).shape != null:
			var dm := (cs as CollisionShape3D).shape.get_debug_mesh()
			if dm == null:
				continue
			var wa: AABB = (cs as CollisionShape3D).global_transform * dm.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


# ---------------- world build (persistent player/env/hud) ----------------

func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	# Look upgrade (env is shared; the Weather3D system reuses it and only overrides sky/ambient, so
	# these survive). ACES tonemap = warm/filmic vs the flat linear default; a touch of contrast +
	# saturation so nothing reads washed-out. Both are Compatibility/WebGL2-safe (Environment GLOW is
	# NOT — neon is faked with emissive + an additive quad per art.md, never env.glow_enabled).
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	# tonemap_white MUST be > 1.0: at the default (1.0) ACES clips ALL radiance >= 1.0 to pure
	# white, so any albedo >= ~0.72 under the noon sun+ambient renders as a detail-free blob
	# (stucco/plaster/limestone/marble all become the same white). 4.0 restores highlight
	# headroom and N.L shading separation on pale walls, day AND night.
	env.tonemap_white = 4.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.12
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true   # contact shadows GROUND props. In CHUNK mode _boot tightens the cascade +
	add_child(sun)              # the floor slab is cast_shadow=OFF, so props cast but the flat floor can't acne.


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY
	player.floor_snap_length = 0.8   # Wave 2: feet stay stuck to descents/stairs (no mid-air hover)
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	cs.shape = cap
	cs.position.y = 0.85
	player.add_child(cs)
	# DEFAULT body = a placeholder capsule. To use a real character, load a .glb
	# (library OR Meshy — SAME path) and SEAT it so its feet rest on the floor
	# (character GLB origins sit at the hips, so feet sink under the floor without this):
	#     var avatar := load("res://models/hero.glb").instantiate() as Node3D
	#     player.add_child(avatar)
	#     _seat_avatar(avatar)            # feet at y=0; then remove the capsule body
	#     # size the CollisionShape capsule from the model's height if it differs.
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.6
	body.mesh = cm
	body.position.y = 0.85
	body.material_override = _mat(Color(0.3, 0.6, 0.95))
	player.add_child(body)
	_capsule_body = body   # kept so a native hero_model attach can hide the placeholder (see _attach_hero_model)
	# Wave 4: the old hardcoded sword MeshInstance is GONE — GEquip attaches the equipped
	# weapon's visual on a "GEquipSlot" node instead (_sync_equip_visual, called from _ready
	# once RpgState exists). The swing routine in _process rotates that slot, same formula.
	# Third-person SpringArm orbit rig: a yaw pivot that follows the player, a
	# collision-aware spring arm (pulls the cam in at walls), and the camera on
	# the tip — empirically the cam lands at +Z*length, auto-aimed at the pivot.
	# Pitch is clamped so it can never dive to the floor; movement is camera-relative.
	cam_rig = Node3D.new()
	add_child(cam_rig)
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = CAM_DIST
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.3
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1   # up from the 0.05 default — better distant depth precision (far stays 4000)
	cam_spring.add_child(cam)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# Bioluminescent spore-motes drifting around the camera — the cheap ambient cue that sells
# the alien world, day and night (CPUParticles3D, additive, ~free).
func _build_motes() -> void:
	var p := CPUParticles3D.new()
	p.amount = 36
	p.lifetime = 7.0
	p.preprocess = 7.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(16, 6, 16)
	p.direction = Vector3(0, 1, 0)
	p.spread = 180.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 0.15
	p.initial_velocity_max = 0.5
	p.scale_amount_min = 0.05
	p.scale_amount_max = 0.12
	p.color = Color(0.35, 0.95, 0.85, 0.8)
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(0.35, 0.95, 0.85, 0.55)
	m.emission_enabled = true
	m.emission = Color(0.25, 0.9, 0.8)
	m.emission_energy_multiplier = 2.0
	mesh.material = m
	p.mesh = mesh
	p.emitting = true
	cam_rig.add_child(p)


# Seat a MODEL avatar so its feet rest on the floor (y=0 at the body origin).
# Library/Meshy character GLBs often have their origin at the hips/centre, so
# without this the feet sink under the floor — props get the same treatment in
# the AreaBuilder; this is the player-side equivalent. Call after add_child().
func _seat_avatar(node: Node3D) -> void:
	node.position.y -= _subtree_aabb(node).position.y


func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


# ---------------- native hero_model (world.json "hero_model") ----------------

# A world-level "hero_model" wears a real character GLB in place of the placeholder capsule — the
# NATIVE form of the _build_player recipe. The GLB is fetched (same GLTFDocument.append_from_buffer
# idiom as area_builder), scaled to the capsule height, feet-seated, and idle-autoplayed. GUARDS:
#  (a) a builder that already wired an avatar the documented way (ANY Skeleton3D under the player)
#      wins — we skip; (b) a single fetch RETRY (saltwind QA P1) before degrading to the capsule.
# Relative paths resolve through _norm, exactly like vehicle/weapon model URLs.
func _attach_hero_model() -> void:
	if player == null:
		return
	var hero := String(world_data.get("hero_model", ""))
	if hero == "":
		return
	if not player.find_children("*", "Skeleton3D", true, false).is_empty():
		print("GOGI_HERO builder-wired avatar detected — native attach skipped")
		return
	var url := _norm(hero)
	if url == "":
		return
	var node: Node3D = null
	for attempt in range(4):
		node = await _fetch_glb_scene(url)
		if node != null:
			break
		await get_tree().create_timer(1.0 + float(attempt)).timeout
	if node == null:
		print("GOGI_HERO attach FAILED after retries: ", url)
		return
	node.name = "GogiHeroAvatar"
	player.add_child(node)
	var ab := _subtree_aabb(node)
	if ab.size.y > 0.001:
		node.scale *= HERO_HEIGHT / ab.size.y   # size to the capsule (~1.65 m tall)
	_seat_avatar(node)                           # character GLB origins sit at the hips — feet to y=0
	if _capsule_body != null and is_instance_valid(_capsule_body):
		_capsule_body.visible = false            # the placeholder body gives way to the avatar
	_play_hero_idle(node)
	print("GOGI_HERO native avatar attached")


# Fetch a GLB by absolute URL -> instanced scene root (null on any failure). Mirrors the builder's
# parse path (append_from_buffer -> generate_scene); the caller owns the single retry.
func _fetch_glb_scene(url: String) -> Node3D:
	var req := HTTPRequest.new()
	add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return null
	var res = await req.request_completed
	req.queue_free()
	if res[1] != 200:
		return null
	var buf := res[3] as PackedByteArray
	if buf.is_empty():
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(buf, "", st) != OK:
		return null
	return doc.generate_scene(st) as Node3D


# Autoplay the hero's idle so it isn't a frozen A-pose. A model that EMBEDS clips (Meshy/library
# creature) plays its own; a clipless KayKit Rig_Medium retargets from the packed kk_rig_medium_*
# libraries via AnimRig (the enemy.gd / crowd idiom). Silent no-op when neither yields a clip.
func _play_hero_idle(node: Node3D) -> void:
	var ap := AnimRig._find_ap(node)
	if ap == null or ap.get_animation_list().is_empty():
		ap = AnimRig.attach(node, {"idle": "Idle_A", "walk": "Walking_A"}, ["idle", "walk"])
	if ap == null:
		return
	var clips := ap.get_animation_list()
	if clips.is_empty():
		return
	var idle := ""
	for c in clips:
		if "idle" in String(c).to_lower():
			idle = c
			break
	if idle == "":
		idle = clips[0]
	ap.play(idle)


func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	stats = Label.new()
	stats.position = Vector2(12, 12)
	stats.add_theme_font_size_override("font_size", 22)
	stats.add_theme_color_override("font_color", Color(0.9, 1.0, 0.9))
	hud_layer.add_child(stats)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.position = Vector2(12, 120)
	bg.size = Vector2(320, 20)
	hud_layer.add_child(bg)
	hp_bar = ColorRect.new()
	hp_bar.color = Color(0.85, 0.25, 0.25)
	hp_bar.position = Vector2(12, 120)
	hp_bar.size = Vector2(320, 20)
	hud_layer.add_child(hp_bar)
	var vp := get_viewport().get_visible_rect().size
	_button("ATTACK", vp - Vector2(250, 180), Vector2(220, 130), _attack)
	_button("USE", vp - Vector2(250, 330), Vector2(220, 120), func() -> void: interaction.try_use())
	_button("POTION", vp - Vector2(490, 180), Vector2(220, 130), func() -> void: rpg.use_potion())
	_button("PACK", vp - Vector2(490, 330), Vector2(220, 120), func() -> void: inv_ui.toggle())

	# contextual ALLY button — appears beside the prompt when near a hostile species elder
	ally_btn = Button.new()
	ally_btn.text = "ALLY"
	ally_btn.add_theme_font_size_override("font_size", 28)
	ally_btn.visible = false
	ally_btn.position = vp - Vector2(250, 460)
	ally_btn.size = Vector2(220, 110)
	ally_btn.pressed.connect(_offer_alliance)
	hud_layer.add_child(ally_btn)

	# red damage vignette (flashes on hits taken)
	damage_vignette = ColorRect.new()
	damage_vignette.color = Color(0.8, 0.1, 0.1, 0.0)
	damage_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	damage_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(damage_vignette)

	# objective nav aid: an arrow + distance pinned top-center (missions mode)
	nav_root = Control.new()
	nav_root.set_anchors_preset(Control.PRESET_CENTER_TOP)
	nav_root.position = Vector2(0, 64)
	nav_root.visible = false
	hud_layer.add_child(nav_root)
	nav_arrow = Polygon2D.new()
	nav_arrow.polygon = PackedVector2Array([Vector2(0, -26), Vector2(18, 14), Vector2(0, 4), Vector2(-18, 14)])
	nav_arrow.color = Color(0.35, 0.95, 0.85)
	nav_root.add_child(nav_arrow)
	nav_label = Label.new()
	nav_label.add_theme_font_size_override("font_size", 20)
	nav_label.add_theme_color_override("font_color", Color(0.35, 0.95, 0.85))
	nav_label.position = Vector2(-60, 22)
	nav_root.add_child(nav_label)


func _button(text: String, pos: Vector2, sz: Vector2, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 28)
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	hud_layer.add_child(b)


# ---------------- XENOREACH: title screen (audio-unlock gate + mode choice) ----------------

func _build_title_screen() -> void:
	title_layer = CanvasLayer.new()
	title_layer.layer = 210
	add_child(title_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.07, 0.96)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_layer.add_child(dim)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.custom_minimum_size = Vector2(520, 0)
	vb.offset_left = -260
	vb.offset_right = 260
	vb.offset_top = -260
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 18)
	title_layer.add_child(vb)
	var title := Label.new()
	title.text = "XENOREACH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(0.35, 0.95, 0.85))
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Stranded apex hunter. A bioluminescent world.\nHunt the five species - or make them your allies."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 24)
	sub.add_theme_color_override("font_color", Color(0.75, 0.82, 0.85))
	vb.add_child(sub)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 14)
	vb.add_child(spacer)
	var b1 := Button.new()
	b1.text = "  EXPLORE - free roam  "
	b1.add_theme_font_size_override("font_size", 32)
	b1.custom_minimum_size = Vector2(0, 84)
	b1.pressed.connect(func() -> void: _pick_mode("explore"))
	vb.add_child(b1)
	var b2 := Button.new()
	b2.text = "  MISSIONS - the hunt  "
	b2.add_theme_font_size_override("font_size", 32)
	b2.custom_minimum_size = Vector2(0, 84)
	b2.pressed.connect(func() -> void: _pick_mode("missions"))
	vb.add_child(b2)
	var hint := Label.new()
	hint.text = "Left side: drag to move   -   Right side: drag to look\nWalk up to beasts, vehicles and ships and press USE to ride, drive or fly\nATTACK fires your equipped weapon - PACK opens your gear"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 19)
	hint.add_theme_color_override("font_color", Color(0.55, 0.62, 0.66))
	vb.add_child(hint)


func _pick_mode(mode: String) -> void:
	play_mode = mode
	AudioManager.unlock()
	if ResourceLoader.exists("res://audio/music_theme.ogg"):
		AudioManager.play_music(load("res://audio/music_theme.ogg"))
	if ResourceLoader.exists("res://audio/ambient_alien.ogg"):
		AudioManager.play_ambient(load("res://audio/ambient_alien.ogg"))
	if title_layer != null:
		title_layer.queue_free()
		title_layer = null
	if mode == "missions" and quest != null and not quest.any_active():
		quest.start_next()
	if save_sys != null:
		save_sys.mark_dirty()
	print("GOGI_MODE ", mode)


# ---------------- XENOREACH: alliance (elder USE + the ALLY button) ----------------

## Nearest hostile-species ELDER within reach -> show the ALLY button targeting its species.
func _scan_elders() -> void:
	if ally_btn == null or interaction == null or player == null:
		return
	var found := ""
	for it in interaction.items:
		if String(it.get("kind", "")) != "npc":
			continue
		var nid := String(it.get("npc_id", ""))
		if not nid.begins_with("elder_"):
			continue
		var sp := nid.trim_prefix("elder_")
		if not species.is_species(sp) or species.is_allied(sp):
			continue
		var p = it.get("pos")
		if p is Vector3 and (p as Vector3).distance_to(player.global_position) < 5.0:
			found = sp
			break
	_ally_target = found
	ally_btn.visible = found != ""
	if found != "":
		ally_btn.text = "ALLY " + species.species_name(found).to_upper()


func _offer_alliance() -> void:
	if _ally_target == "" or species == null:
		return
	var sp := _ally_target
	if species.ally(sp):
		AudioManager.play_sfx("pickup", 0.0, 0.7)
		interaction._show(["The %s accept you. Their hunters now fight at your side." % species.species_name(sp)])
		if save_sys != null:
			save_sys.save_now()
	ally_btn.visible = false
	_ally_target = ""


# ---------------- XENOREACH: objective nav aid ----------------

func _update_nav_aid() -> void:
	if nav_root == null or quest == null or player == null:
		return
	if play_mode != "missions":
		nav_root.visible = false
		return
	var m := quest.active_marker()
	if m.is_empty():
		nav_root.visible = false
		return
	nav_root.visible = true
	var target := Vector3(float(m[0]), 0.0, float(m[1]))
	var d := target - player.global_position
	d.y = 0.0
	var dist := d.length()
	# world dir -> screen dir: unrotate by the camera orbit yaw (screen-up = -z)
	var s := Basis(Vector3.UP, -cam_yaw) * d
	nav_arrow.rotation = atan2(s.x, -s.z)
	nav_label.text = "OBJECTIVE %dm" % int(dist)


# ---------------- XENOREACH: juice (shake + vignette) ----------------

func _shake_camera(strength: float) -> void:
	if cam == null:
		return
	var tw := cam.create_tween()   # bound to the camera node
	for i in range(4):
		var off := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0.0) * strength * (1.0 - float(i) / 4.0)
		tw.tween_property(cam, "position", off, 0.04)
	tw.tween_property(cam, "position", Vector3.ZERO, 0.05)


func _flash_vignette() -> void:
	if damage_vignette == null:
		return
	damage_vignette.color.a = 0.28
	var tw := damage_vignette.create_tween()
	tw.tween_property(damage_vignette, "color:a", 0.0, 0.4)


# ---------------- XENOREACH: hero locomotion (idle/walk/run by live speed) ----------------

func _wire_hero_locomotion() -> void:
	if player == null:
		return
	var avatar := player.find_child("GogiHeroAvatar", true, false)
	if avatar == null:
		return
	_hero_ap = AnimRig._find_ap(avatar)
	if _hero_ap == null:
		return
	for c in _hero_ap.get_animation_list():
		var l := String(c).to_lower()
		if _hero_idle == "" and "idle" in l:
			_hero_idle = c
		elif _hero_run == "" and "run" in l:
			_hero_run = c
		elif _hero_walk == "" and "walk" in l:
			_hero_walk = c
	if _hero_walk == "":
		_hero_walk = _hero_run
	if _hero_run == "":
		_hero_run = _hero_walk
	print("GOGI_HERO clips idle=%s walk=%s run=%s" % [_hero_idle, _hero_walk, _hero_run])


func _play_hero(clip: String) -> void:
	if _hero_ap == null or clip == "" or _hero_cur == clip:
		return
	_hero_cur = clip
	if _hero_ap.has_animation(clip):
		var a := _hero_ap.get_animation(clip)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR
		_hero_ap.play(clip, 0.15)


func _update_hero_anim() -> void:
	if _hero_ap == null or player == null:
		return
	# riding / driving / seated / swimming: GPose owns the skeleton — pause the clips
	var posed := (active_vehicle != null and is_instance_valid(active_vehicle)) \
		or (interaction != null and interaction.player_seated) or swimming or climbing != null
	if posed:
		if _hero_ap.is_playing():
			_hero_ap.pause()
			_hero_cur = ""
		return
	var hs := Vector2(player.velocity.x, player.velocity.z).length()
	if hs > 4.5:
		_play_hero(_hero_run)
	elif hs > 0.6:
		_play_hero(_hero_walk)
	else:
		_play_hero(_hero_idle)
