class_name InventoryUI extends Node
## The hunter's PACK: a slide-in panel listing WEAPONS (tap to equip — a real switchable
## arsenal, not just auto-equip), TROPHIES & SOUVENIRS (from kills + landmarks), and
## TREASURE (gold). Rebuilt from RpgState on every open + on any state change while open.

var rpg: RpgState = null
var species: SpeciesSystem = null
var panel: PanelContainer = null
var list: VBoxContainer = null
var open := false


func setup(hud: CanvasLayer, state: RpgState, sp: SpeciesSystem) -> void:
	rpg = state
	species = sp
	rpg.changed.connect(_refresh_if_open)
	sp.changed.connect(_refresh_if_open)

	panel = PanelContainer.new()
	panel.visible = false
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(560, 640)
	panel.offset_left = -280
	panel.offset_right = 280
	panel.offset_top = -320
	panel.offset_bottom = 320
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.07, 0.10, 0.93)
	style.border_color = Color(0.15, 0.75, 0.70)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	hud.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var head := HBoxContainer.new()
	vb.add_child(head)
	var title := Label.new()
	title.text = "HUNTER'S PACK"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.35, 0.95, 0.85))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "  X  "
	close.add_theme_font_size_override("font_size", 26)
	close.pressed.connect(toggle)
	head.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)


func toggle() -> void:
	open = not open
	panel.visible = open
	if open:
		AudioManager.play_sfx("ui")
		_rebuild()


func _refresh_if_open() -> void:
	if open:
		_rebuild()


func _rebuild() -> void:
	for c in list.get_children():
		c.queue_free()
	var counts := {}
	for id in rpg.inventory:
		counts[id] = int(counts.get(id, 0)) + 1

	_header("WEAPONS")
	var any_w := false
	for id in counts:
		if not rpg.weapons.has(String(id)):
			continue
		any_w = true
		var def: Dictionary = rpg.weapon_def(String(id))
		var row := HBoxContainer.new()
		list.add_child(row)
		var lbl := Label.new()
		var eq := String(id) == rpg.equipped_weapon
		lbl.text = "%s%s  (%s, dmg %d)" % ["> " if eq else "  ", String(def.get("name", id)),
			String(def.get("kind", "melee")), int(def.get("damage", 1))]
		lbl.add_theme_font_size_override("font_size", 22)
		lbl.add_theme_color_override("font_color", Color(0.95, 0.9, 0.55) if eq else Color(0.85, 0.88, 0.9))
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		if not eq:
			var b := Button.new()
			b.text = "EQUIP"
			b.add_theme_font_size_override("font_size", 20)
			var wid := String(id)
			b.pressed.connect(func() -> void:
				rpg.equip(wid, true)
				AudioManager.play_sfx("pickup")
				_rebuild())
			row.add_child(b)
	if not any_w:
		_line("(no weapons)")

	_header("TROPHIES & SOUVENIRS")
	var any_t := false
	for id in counts:
		if rpg.item_type(String(id)) != "souvenir":
			continue
		any_t = true
		var n := int(counts[id])
		_line("%s%s" % [rpg.item_name(String(id)), (" x%d" % n) if n > 1 else ""])
	if not any_t:
		_line("(hunt beasts and explore ruins to collect trophies)")

	_header("TREASURE")
	_line("Gold shards: %d" % rpg.gold)
	for id in counts:
		if rpg.item_type(String(id)) == "consumable":
			_line("%s x%d" % [rpg.item_name(String(id)), int(counts[id])])

	_header("SPECIES STANDING")
	for sid in species.SPECIES:
		var allied := species.is_allied(String(sid))
		var l := Label.new()
		l.text = "%s - %s  (%s)" % [species.species_name(String(sid)),
			"ALLIED" if allied else "HOSTILE", String(species.SPECIES[sid]["desc"])]
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color(0.4, 0.95, 0.6) if allied else Color(0.95, 0.5, 0.4))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(l)


func _header(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", Color(0.35, 0.8, 0.95))
	list.add_child(l)


func _line(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 22)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(l)
