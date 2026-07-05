extends CharacterBody3D
## Enemy: CharacterBody3D + NavigationAgent3D chase with RVO avoidance so enemies ENCIRCLE
## the player (distinct slot angle per index) instead of clumping. Melee w/ cooldown,
## health, death. The streamed KayKit skeleton GLBs carry NO embedded clips, so the
## animations are RETARGETED from the packed kk_rig_medium_* libraries via AnimRig
## (anim_rig.gd) — see animation.md. Falls back to no-anim if those libs aren't packed.
##
## XENOREACH species layer: each alien species carries a signature power —
##   skarn = acid spit (ranged glob), veyth = light-bend cloak, gorra = crushing charge,
##   mylah = heals nearby kin, broodmaw = the boss (huge HP, slam + acid).
## An ALLIED species member (SpeciesSystem) stops hunting the player and fights hostile
## aliens at the player's side instead; hitting an ally is a betrayal (species turns hostile).

const FLASH_TIME := 0.12

# per-species tuning: hp / speed / melee dmg / attack range / model height (m)
const STATS := {
	"skarn":    {"hp": 40.0,  "speed": 3.2, "dmg": 7.0,  "range": 2.0, "height": 1.7},
	"veyth":    {"hp": 50.0,  "speed": 3.8, "dmg": 12.0, "range": 2.0, "height": 2.0},
	"gorra":    {"hp": 85.0,  "speed": 2.9, "dmg": 11.0, "range": 2.3, "height": 2.3},
	"mylah":    {"hp": 35.0,  "speed": 3.0, "dmg": 6.0,  "range": 2.0, "height": 1.9},
	"broodmaw": {"hp": 420.0, "speed": 2.6, "dmg": 22.0, "range": 3.2, "height": 3.4},
}

var world: Node
var player: Node3D
var anim: AnimationPlayer
var agent: NavigationAgent3D
var mesh_root: Node3D

var hp := 45.0
var max_hp := 45.0
var speed := 3.3
var kind := "skeleton"      # reported on death -> kill_count quest match (honors cell.enemy_type)
var dead := false
var atk_cd := 0.0
var flash_t := 0.0
var slot_angle := 0.0       # distinct approach angle so enemies encircle, not clump
var surround_radius := 1.7
var attack_range := 2.0
var melee_dmg := 9.0

# species power state
var power := ""             # "acid" | "cloak" | "charge" | "heal" | "boss" | ""
var spit_cd := 0.0
var heal_cd := 0.0
var charge_cd := 0.0
var charging_t := 0.0
var charge_dir := Vector3.ZERO
var cloaked := false
var decloak_t := 0.0        # forced-visible window after taking a hit
var _ally_marker: MeshInstance3D = null
var _ally_atk_cd := 0.0
var _meshes: Array = []     # cached MeshInstance3D list (flash / cloak)

static var _flash_mat: StandardMaterial3D = null


func setup(p: Node3D, model: Node, w: Node, index := 0, total := 1, etype := "skeleton") -> void:
	player = p
	world = w
	kind = etype
	collision_layer = 4   # enemy layer
	collision_mask = 1    # world only; RVO avoidance handles enemy separation
	slot_angle = TAU * float(index) / float(max(1, total))
	speed = 3.0 + float(index % 4) * 0.3   # desync so they don't move as one blob

	var st: Dictionary = STATS.get(etype, {})
	if not st.is_empty():
		hp = float(st.get("hp", 45.0))
		max_hp = hp
		speed = float(st.get("speed", speed)) + float(index % 3) * 0.2
		melee_dmg = float(st.get("dmg", 9.0))
		attack_range = float(st.get("range", 2.0))
		var powers := {"skarn": "acid", "veyth": "cloak", "gorra": "charge", "mylah": "heal", "broodmaw": "boss"}
		power = String(powers.get(etype, ""))
	else:
		max_hp = hp

	var body_h := float(st.get("height", 1.5)) if not st.is_empty() else 1.5
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4 if power != "boss" else 0.8
	cap.height = body_h
	cs.shape = cap
	cs.position.y = body_h * 0.5
	add_child(cs)

	agent = NavigationAgent3D.new()
	agent.radius = 0.55
	agent.height = 1.5
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.4
	agent.avoidance_enabled = true
	agent.neighbor_distance = 4.0
	agent.max_neighbors = 10
	agent.max_speed = speed
	add_child(agent)
	agent.velocity_computed.connect(_on_safe_velocity)
	if power == "boss":
		surround_radius = 2.4

	if model:
		mesh_root = Node3D.new()
		add_child(mesh_root)
		mesh_root.add_child(model)
		# normalize the streamed GLB to the species height + seat feet at y=0 (GLB origins vary)
		if model is Node3D:
			var m3 := model as Node3D
			var ab := _model_aabb(m3)
			if ab.size.y > 0.05:
				m3.scale *= body_h / ab.size.y
				ab = _model_aabb(m3)
			m3.position.y -= ab.position.y
		anim = _find_anim(model)
		if anim == null and model is Node3D:
			# Streamed KayKit skeletons ship with NO embedded clips — retarget from
			# the packed kk_rig_medium_* libraries (fetch them into res://models/).
			anim = AnimRig.attach(model as Node3D, {
				"idle": "Idle_A", "walk": "Walking_A",
				"attack": "Melee_1H_Attack_Chop", "death": "Death_A",
			}, ["idle", "walk"])
		_resolve_clips()
		_play(c_idle)
	else:
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.4
		cm.height = body_h
		mi.mesh = cm
		mi.position.y = body_h * 0.5
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.8, 0.3, 0.3)
		mi.material_override = m
		add_child(mi)
		mesh_root = mi
	_cache_meshes()


var c_idle := ""
var c_walk := ""
var c_attack := ""
var c_die := ""
var _cur := ""


func _physics_process(delta: float) -> void:
	if dead or not is_instance_valid(player):
		return
	atk_cd = max(0.0, atk_cd - delta)
	flash_t = max(0.0, flash_t - delta)
	spit_cd = max(0.0, spit_cd - delta)
	heal_cd = max(0.0, heal_cd - delta)
	charge_cd = max(0.0, charge_cd - delta)
	decloak_t = max(0.0, decloak_t - delta)
	_ally_atk_cd = max(0.0, _ally_atk_cd - delta)

	if _is_allied():
		_set_cloak(false)
		_allied_tick(delta)
		return
	if _ally_marker != null and is_instance_valid(_ally_marker):
		_ally_marker.visible = false

	var ppos: Vector3 = player.global_position
	var to: Vector3 = ppos - global_position
	to.y = 0.0
	var dist := to.length()
	var desired := Vector3.ZERO

	# --- CHARGE (gorra): a committed rush along a captured heading ---
	if charging_t > 0.0:
		charging_t = max(0.0, charging_t - delta)
		velocity = charge_dir * (speed * 3.6)
		velocity.y = 0.0
		move_and_slide()
		_face(charge_dir)
		if dist < 1.8:
			charging_t = 0.0
			_play(c_attack, false)
			if player.has_method("take_damage"):
				player.call("take_damage", 18.0)
		return
	if power == "charge" and charge_cd <= 0.0 and dist > 5.0 and dist < 16.0:
		charge_cd = 6.0
		charging_t = 1.1
		charge_dir = to.normalized()
		_play(c_walk)
		AudioManager.play_sfx("attack", -4.0, 0.7)

	# --- CLOAK (veyth): near-invisible until close (or recently hit) ---
	if power == "cloak":
		_set_cloak(dist > 5.0 and decloak_t <= 0.0)

	# --- ACID SPIT (skarn + boss): a glowing glob lobbed at the player ---
	if (power == "acid" or power == "boss") and spit_cd <= 0.0 and dist > 3.0 and dist < 18.0:
		spit_cd = 3.0 if power == "acid" else 2.2
		_spit_acid(ppos)

	# --- HEAL (mylah): pulse-heals wounded kin nearby ---
	if power == "heal" and heal_cd <= 0.0:
		var healed := _heal_allies()
		if healed:
			heal_cd = 4.0

	# attack when in range, INDEPENDENT of movement (so they don't stop and pile up)
	if dist <= attack_range and atk_cd <= 0.0:
		atk_cd = 1.3
		_play(c_attack, false)
		if player.has_method("take_damage"):
			player.call("take_damage", melee_dmg)

	# ALWAYS seek a DISTINCT slot around the player -> enemies encircle, not bunch
	var slot := ppos + Vector3(cos(slot_angle), 0.0, sin(slot_angle)) * surround_radius
	agent.target_position = slot
	var next := agent.get_next_path_position()
	var dir := next - global_position
	dir.y = 0.0
	if dir.length() < 0.05:   # fallback if navmesh path is degenerate
		dir = slot - global_position
		dir.y = 0.0
	_face(to)   # always look at the player while circling/attacking
	if dir.length() > 0.2:
		desired = dir.normalized() * speed
		if _cur != c_attack:
			_play(c_walk)
	elif _cur != c_attack:
		_play(c_idle)

	# feed desired velocity into RVO avoidance; actual move happens in the callback
	agent.set_velocity(desired)


# ---------------- allied (companion) behavior ----------------

func _is_allied() -> bool:
	return is_instance_valid(world) and world.has_method("is_species_allied") \
		and world.call("is_species_allied", kind)


func _allied_tick(_delta: float) -> void:
	_ensure_ally_marker()
	var target := _nearest_hostile()
	var desired := Vector3.ZERO
	if target != null:
		var to: Vector3 = target.global_position - global_position
		to.y = 0.0
		var d := to.length()
		_face(to)
		if d <= attack_range + 0.4:
			if _ally_atk_cd <= 0.0:
				_ally_atk_cd = 1.3
				_play(c_attack, false)
				if target.has_method("take_hit"):
					target.call("take_hit", melee_dmg + 4.0, false)
		else:
			desired = to.normalized() * speed
			if _cur != c_attack:
				_play(c_walk)
	else:
		# no fight nearby: an allied mylah tends the hunter's wounds; others loosely follow
		if power == "heal" and heal_cd <= 0.0:
			var pd := global_position.distance_to(player.global_position)
			if pd < 9.0 and world.has_method("heal_player") and world.call("heal_player", 8.0):
				heal_cd = 5.0
				_heal_ring(global_position)
		var to_p: Vector3 = player.global_position - global_position
		to_p.y = 0.0
		if to_p.length() > 6.0 and to_p.length() < 26.0:
			desired = to_p.normalized() * (speed * 0.9)
			_face(to_p)
			_play(c_walk)
		else:
			_play(c_idle)
	agent.set_velocity(desired)


func _nearest_hostile() -> Node3D:
	if not (is_instance_valid(world) and world.has_method("live_enemy_list")):
		return null
	var best: Node3D = null
	var bd := 16.0
	var listing: Array = world.call("live_enemy_list")
	for e in listing:
		if e == self or not is_instance_valid(e):
			continue
		if e.get("dead"):
			continue
		var ek := String(e.get("kind"))
		if ek == kind:
			continue
		if world.call("is_species_allied", ek):
			continue
		var d: float = global_position.distance_to((e as Node3D).global_position)
		if d < bd:
			bd = d
			best = e as Node3D
	return best


func _ensure_ally_marker() -> void:
	if _ally_marker != null and is_instance_valid(_ally_marker):
		_ally_marker.visible = true
		return
	_ally_marker = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	_ally_marker.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.2, 0.95, 0.85)
	m.emission_enabled = true
	m.emission = Color(0.2, 0.95, 0.85)
	m.emission_energy_multiplier = 3.0
	_ally_marker.material_override = m
	var h := 2.2
	if not STATS.get(kind, {}).is_empty():
		h = float(STATS[kind]["height"]) + 0.5
	_ally_marker.position.y = h
	add_child(_ally_marker)


# ---------------- species powers ----------------

func _spit_acid(target_pos: Vector3) -> void:
	var par := get_parent()
	if par == null:
		return
	_play(c_attack, false)
	AudioManager.play_sfx("attack", -6.0, 1.5)
	var glob := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.36
	glob.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.5, 0.95, 0.1)
	m.emission_enabled = true
	m.emission = Color(0.5, 0.95, 0.1)
	m.emission_energy_multiplier = 4.0
	glob.material_override = m
	par.add_child(glob)
	glob.global_position = global_position + Vector3(0, 1.4, 0)
	var dest := target_pos + Vector3(0, 0.9, 0)
	var flight := clampf(glob.global_position.distance_to(dest) / 14.0, 0.15, 1.4)
	var dmg := 8.0 if power == "acid" else 12.0
	var me := self
	var pl := player
	var tw := glob.create_tween()   # bound to the glob — dies with it (never the scene root)
	tw.tween_property(glob, "global_position", dest, flight)
	tw.tween_callback(func() -> void:
		if is_instance_valid(pl) and glob.global_position.distance_to(pl.global_position + Vector3(0, 0.9, 0)) < 1.7:
			if pl.has_method("take_damage"):
				pl.call("take_damage", dmg)
		if is_instance_valid(me):
			me._burst(glob.global_position, Color(0.5, 0.95, 0.1), 14)
		glob.queue_free())


func _heal_allies() -> bool:
	if not (is_instance_valid(world) and world.has_method("live_enemy_list")):
		return false
	var any := false
	var listing: Array = world.call("live_enemy_list")
	for e in listing:
		if not is_instance_valid(e) or e.get("dead"):
			continue
		var ehp := float(e.get("hp"))
		var emax := float(e.get("max_hp"))
		if ehp >= emax:
			continue
		if global_position.distance_to((e as Node3D).global_position) > 8.0:
			continue
		e.set("hp", minf(emax, ehp + 12.0))
		any = true
	if any:
		_heal_ring(global_position)
	return any


func _heal_ring(at: Vector3) -> void:
	var par := get_parent()
	if par == null:
		return
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.7
	tm.outer_radius = 0.85
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.75, 0.25)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.75, 0.25)
	m.emission_energy_multiplier = 3.0
	ring.material_override = m
	par.add_child(ring)
	ring.global_position = at + Vector3(0, 0.4, 0)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(4.0, 1.0, 4.0), 0.7)
	tw.tween_property(ring, "transparency", 1.0, 0.7)
	tw.chain().tween_callback(ring.queue_free)


func _set_cloak(on: bool) -> void:
	if cloaked == on:
		return
	cloaked = on
	for mi: MeshInstance3D in _meshes:
		if is_instance_valid(mi):
			mi.transparency = 0.88 if on else 0.0


# ---------------- damage / death (THE one damage door) ----------------

## Melee (main._attack), projectiles (GProjectile), AND allied companions all land here.
## from_player=true (the default) marks damage dealt by the hunter — striking an ALLIED
## species member betrays the alliance (the species turns hostile).
func take_hit(d: float, from_player := true) -> void:
	if dead:
		return
	if from_player and _is_allied() and is_instance_valid(world) and world.has_method("on_ally_betrayed"):
		world.call("on_ally_betrayed", kind)
	hp -= d
	flash_t = FLASH_TIME
	decloak_t = 2.5
	_set_cloak(false)
	_flash()
	_burst(global_position + Vector3(0, 1.1, 0), Color(1.0, 0.85, 0.4), 10)
	AudioManager.play_sfx("hit")
	if hp <= 0.0:
		_die()


func _die() -> void:
	dead = true
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	if is_instance_valid(world) and world.has_method("on_enemy_killed"):
		world.on_enemy_killed(kind)   # -> XP + quest kill progress (authored enemy_type)
	_play(c_die, false)
	var t := create_tween()
	t.tween_interval(1.1)
	t.tween_callback(queue_free)


# ---------------- juice ----------------

func _flash() -> void:
	if _flash_mat == null:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_mat.albedo_color = Color(1, 1, 1, 0.7)
		_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for mi: MeshInstance3D in _meshes:
		if is_instance_valid(mi):
			mi.material_overlay = _flash_mat
	var tw := create_tween()   # bound to the enemy — dies with it
	tw.tween_interval(FLASH_TIME)
	tw.tween_callback(func() -> void:
		for mi: MeshInstance3D in _meshes:
			if is_instance_valid(mi):
				mi.material_overlay = null)


func _burst(at: Vector3, col: Color, n: int) -> void:
	var par := get_parent()
	if par == null:
		return
	var p := CPUParticles3D.new()
	p.amount = n
	p.one_shot = true
	p.lifetime = 0.45
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.5
	p.gravity = Vector3(0, -9.0, 0)
	p.scale_amount_min = 0.06
	p.scale_amount_max = 0.14
	p.color = col
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = col
	var bm := BoxMesh.new()
	bm.size = Vector3(0.08, 0.08, 0.08)
	bm.material = pm
	p.mesh = bm
	par.add_child(p)
	p.global_position = at
	p.emitting = true
	var tw := p.create_tween()   # bound to the particles node
	tw.tween_interval(0.8)
	tw.tween_callback(p.queue_free)


# ---------------- anim ----------------

func _on_safe_velocity(safe: Vector3) -> void:
	if dead:
		return
	velocity = Vector3(safe.x, 0.0, safe.z)
	move_and_slide()


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


func _resolve_clips() -> void:
	c_idle = _pick(["idle"])
	c_walk = _pick(["walk", "run", "move"])
	c_attack = _pick(["attack", "melee", "swing", "slash", "punch"])
	c_die = _pick(["death", "die", "dead"])


func _pick(keys: Array) -> String:
	if anim == null:
		return ""
	for n in anim.get_animation_list():
		var l := n.to_lower()
		for k in keys:
			if k in l:
				return n
	return ""


func _play(clip: String, loop := true) -> void:
	if anim == null or clip == "" or _cur == clip:
		return
	_cur = clip
	if anim.has_animation(clip):
		var a := anim.get_animation(clip)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		anim.play(clip)


func _face(dir: Vector3) -> void:
	if dir.length() < 0.05:
		return
	var look := global_position - Vector3(dir.x, 0.0, dir.z)
	look_at(Vector3(look.x, global_position.y, look.z), Vector3.UP)


func _cache_meshes() -> void:
	_meshes = []
	for mi in find_children("*", "MeshInstance3D", true, false):
		_meshes.append(mi)


# Merged mesh AABB in the PARENT frame of `root` (accumulates nested node transforms,
# including root's own scale) — tree-independence matters: setup runs mid-build.
func _model_aabb(root: Node3D) -> AABB:
	var out: Array = [AABB(), true]
	_accum_aabb(root, Transform3D.IDENTITY, out)
	return out[0]


func _accum_aabb(n: Node, xf: Transform3D, out: Array) -> void:
	var local_xf := xf
	if n is Node3D:
		local_xf = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var wa: AABB = local_xf * (n as MeshInstance3D).get_aabb()
		if out[1]:
			out[0] = wa
			out[1] = false
		else:
			out[0] = (out[0] as AABB).merge(wa)
	for c in n.get_children():
		_accum_aabb(c, local_xf, out)
