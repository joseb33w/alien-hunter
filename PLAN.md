# Goal
Xenoreach — a 3D open-world alien-hunter game for mobile web (Godot 4.6.3, Compatibility renderer, nothreads web export) with a Supabase backend. The player is a Predator-style hunter stranded on a bioluminescent alien world: third-person free-roam + a mission chain, five distinct alien species (acid-spitter / cloaker / charger / healer / boss) that can each be hunted OR allied, a switchable weapon inventory with looted species weapons, trophies + treasure, rideable alien mounts (fast / heavy / flying), drivable land vehicles (buggy + tracked crawler, with reverse), a flyable ship and a boat, swimmable water, roads, a day→sunset→night→dawn cycle with rain and storms, and cross-session persistence (inventory, missions, alliances, position) in Supabase.

# Files to touch
- New repo `joseb33w/alien-hunter` built on the `godot-tmpl-rpg` chunk-mode streaming template.
- `world.json` (Architect-designed 12x12 chunk world: biomes, camps, ruins, roads, water, vehicles, landmarks) + `quests.json` (5-mission chain with markers).
- New systems: `species.gd` (per-species reputation), `save_system.gd` (Supabase persistence), `inventory_ui.gd` (PACK panel).
- Extended: `enemy.gd` (species stats + powers + allied-companion AI + hit juice), `main.gd` (title screen w/ Explore & Missions, nav aid, ALLY button, loot, hero locomotion, victory), `quest.gd` (mission chaining + markers), `rpg_systems.gd` (trophy catalog).
- Meshy-generated cast: hunter player, 5 species, elder NPC, 3 rigged mounts, 4 landmark buildings (streamed from R2).
- Supabase: `usr_nmexs7bytxq2_alien_hunter_saves` (RLS enabled; anon select/insert/update only, keyed by device UUID).

# Verification approach
qgcheck winnability gate on world.json + quests.json; headless import + web export (nothreads); vetted verify.mjs smoke (boot, canvas, frames, console); targeted checks — hero facing (W/S drive frames), combat delta (enemy hp before/after + feedback), species powers logic, ally flow, save round-trip against real Supabase, vehicle board/reverse, mobile portrait+landscape fill; independent QA specialist pass before PR.

# Out of scope
Multiplayer; authenticated user accounts (email confirmation is enforced on the shared project, so saves are keyed by a device UUID instead); in-game world editor.
