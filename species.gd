class_name SpeciesSystem extends Node
## Per-species faction state: every alien species is HOSTILE by default; the player can ALLY
## with a species (via its camp elder) which turns its members friendly — they stop attacking
## and fight hostiles alongside the player. Killing a member of an allied species is a
## betrayal: the species flips back to hostile. State persists via SaveSystem.

signal changed

const SPECIES := {
	"skarn":    {"name": "Skarn",    "power": "acid",   "desc": "spits corrosive acid"},
	"veyth":    {"name": "Veyth",    "power": "cloak",  "desc": "bends light to vanish"},
	"gorra":    {"name": "Gorra",    "power": "charge", "desc": "charges with crushing force"},
	"mylah":    {"name": "Mylah",    "power": "heal",   "desc": "mends the wounds of its kin"},
	"broodmaw": {"name": "Broodmaw", "power": "boss",   "desc": "the apex terror of this world"},
}

var rep := {}   # species id -> "hostile" | "allied"
var rpg: RpgState = null


func setup(state: RpgState) -> void:
	rpg = state
	for id in SPECIES:
		if not rep.has(id):
			rep[id] = "hostile"


func is_species(id: String) -> bool:
	return SPECIES.has(id)


func is_allied(id: String) -> bool:
	return String(rep.get(id, "hostile")) == "allied"


func ally(id: String) -> bool:
	if not SPECIES.has(id) or is_allied(id):
		return false
	rep[id] = "allied"
	if rpg != null:
		rpg.set_flag("allied_" + id)
		rpg.set_flag("allied_any")
	changed.emit()
	return true


## The player killed a member: an allied species is betrayed back to hostile.
func on_member_killed(id: String) -> void:
	if SPECIES.has(id) and is_allied(id):
		rep[id] = "hostile"
		changed.emit()


func species_name(id: String) -> String:
	return String(SPECIES.get(id, {}).get("name", id.capitalize()))


func summary() -> String:
	var parts: Array = []
	for id in SPECIES:
		parts.append("%s: %s" % [species_name(id), String(rep.get(id, "hostile")).to_upper()])
	return "\n".join(parts)


func to_dict() -> Dictionary:
	return rep.duplicate()


func from_dict(d: Dictionary) -> void:
	for id in d:
		if SPECIES.has(String(id)):
			rep[String(id)] = String(d[id])
	changed.emit()
