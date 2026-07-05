class_name SaveSystem extends Node
## Supabase persistence: the whole run (inventory, equipped weapon, gold/XP, quest progress,
## per-species alliance state, player position) survives a refresh. One row per DEVICE keyed
## by an unguessable UUID kept in localStorage (web) / user:// (native) — the anon publishable
## key is the client credential, RLS is enabled on the table (anon: select/insert/update only).

const SB_URL := "https://xhhmxabftbyxrirvvihn.supabase.co"
const SB_KEY := "sb_publishable_NZHoIxqqpSvVBP8MrLHCYA_gmg1AbN-"
const TABLE := "usr_nmexs7bytxq2_alien_hunter_saves"
const AUTOSAVE_SEC := 10.0

var main: Node = null
var rpg: RpgState = null
var quest: QuestSystem = null
var species: SpeciesSystem = null
var device_key := ""
var _dirty := false
var _saving := false
var loaded_state := {}   # the state fetched at boot (empty dict = fresh run)


func setup(m: Node, state: RpgState, q: QuestSystem, sp: SpeciesSystem) -> void:
	main = m
	rpg = state
	quest = q
	species = sp
	device_key = _device_key()
	var t := Timer.new()
	t.wait_time = AUTOSAVE_SEC
	t.autostart = true
	t.timeout.connect(_autosave_tick)
	add_child(t)
	rpg.changed.connect(mark_dirty)
	species.changed.connect(save_now)
	quest.objective_changed.connect(mark_dirty)


func mark_dirty() -> void:
	_dirty = true


func _autosave_tick() -> void:
	if _dirty:
		save_now()


# ---------------- device identity ----------------

func _device_key() -> String:
	if OS.has_feature("web"):
		var got = JavaScriptBridge.eval("localStorage.getItem('xenoreach_save_key') || ''", true)
		var k := String(got) if typeof(got) == TYPE_STRING else ""
		if k.length() == 36:
			return k
		k = _uuid4()
		JavaScriptBridge.eval("localStorage.setItem('xenoreach_save_key', '%s')" % k, true)
		return k
	var path := "user://save_key.txt"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var k := f.get_as_text().strip_edges()
		f.close()
		if k.length() == 36:
			return k
	var k2 := _uuid4()
	var w := FileAccess.open(path, FileAccess.WRITE)
	w.store_string(k2)
	w.close()
	return k2


func _uuid4() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var b: Array = []
	for i in range(16):
		b.append(rng.randi_range(0, 255))
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	var hex := ""
	for i in range(16):
		hex += "%02x" % b[i]
		if i in [3, 5, 7, 9]:
			hex += "-"
	return hex


# ---------------- collect / apply ----------------

func collect_state() -> Dictionary:
	var pos: Array = [0.0, 0.0, 0.0]
	var pl = main.get("player")
	if pl != null and is_instance_valid(pl):
		var p: Vector3 = (pl as Node3D).global_position
		pos = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
	var qs := {}
	for id in quest.st:
		var s: Dictionary = quest.st[id]
		qs[String(id)] = {
			"status": String(s.get("status", "inactive")),
			"kills": s.get("kills", {}),
			"reached": s.get("reached", {}),
			"talked": s.get("talked", {}),
		}
	return {
		"v": 1,
		"pos": pos,
		"hp": rpg.hp, "max_hp": rpg.max_hp,
		"level": rpg.level, "xp": rpg.xp, "xp_next": rpg.xp_next,
		"gold": rpg.gold,
		"inventory": rpg.inventory.duplicate(),
		"equipped": rpg.equipped_weapon,
		"flags": rpg.flags.duplicate(),
		"quests": qs,
		"rep": species.to_dict(),
		"mode": String(main.get("play_mode")),
	}


## Restore everything EXCEPT position (main teleports after the streamer boots).
func apply_state(s: Dictionary) -> void:
	rpg.hp = float(s.get("hp", rpg.hp))
	rpg.max_hp = float(s.get("max_hp", rpg.max_hp))
	rpg.level = int(s.get("level", rpg.level))
	rpg.xp = int(s.get("xp", rpg.xp))
	rpg.xp_next = int(s.get("xp_next", rpg.xp_next))
	rpg.gold = int(s.get("gold", rpg.gold))
	var inv = s.get("inventory", null)
	if inv is Array and not (inv as Array).is_empty():
		rpg.inventory = []
		for it in inv:
			rpg.inventory.append(String(it))
	var eq := String(s.get("equipped", ""))
	if eq != "" and rpg.has_item(eq):
		rpg.equipped_weapon = eq
	var fl = s.get("flags", null)
	if fl is Dictionary:
		for f in fl:
			rpg.flags[String(f)] = bool(fl[f])
	var qs = s.get("quests", null)
	if qs is Dictionary:
		for id in qs:
			if quest.st.has(String(id)) and qs[id] is Dictionary:
				var src: Dictionary = qs[id]
				quest.st[String(id)]["status"] = String(src.get("status", "inactive"))
				quest.st[String(id)]["kills"] = src.get("kills", {})
				quest.st[String(id)]["reached"] = src.get("reached", {})
				quest.st[String(id)]["talked"] = src.get("talked", {})
	var rp = s.get("rep", null)
	if rp is Dictionary:
		species.from_dict(rp)
	rpg.changed.emit()
	quest.objective_changed.emit()


func saved_position() -> Variant:
	var p = loaded_state.get("pos", null)
	if p is Array and (p as Array).size() >= 3:
		var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
		if v.length() > 0.01:
			return v
	return null


# ---------------- Supabase I/O ----------------

func load_state() -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	var url := "%s/rest/v1/%s?id=eq.%s&select=data" % [SB_URL, TABLE, device_key]
	if req.request(url, _headers()) != OK:
		req.queue_free()
		return {}
	var res = await req.request_completed
	req.queue_free()
	if res[1] != 200:
		return {}
	var body = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if body is Array and (body as Array).size() > 0 and body[0] is Dictionary:
		var d = (body[0] as Dictionary).get("data", null)
		if d is Dictionary:
			loaded_state = d
			return d
	return {}


var _pending := false


func save_now() -> void:
	if main == null or rpg == null:
		return
	if _saving:
		_pending = true   # a save is in flight — the drain loop below re-saves the LATEST state
		return
	_saving = true
	_dirty = false
	while true:
		_pending = false
		var req := HTTPRequest.new()
		add_child(req)
		var payload := JSON.stringify([{"id": device_key, "user_id": "device", "data": collect_state()}])
		var hdrs := _headers()
		hdrs.append("Prefer: resolution=merge-duplicates")
		var url := "%s/rest/v1/%s" % [SB_URL, TABLE]
		if req.request(url, hdrs, HTTPClient.METHOD_POST, payload) == OK:
			await req.request_completed
		req.queue_free()
		if not _pending:
			break
	_saving = false


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SB_KEY,
		"Authorization: Bearer " + SB_KEY,
		"Content-Type: application/json",
	])
