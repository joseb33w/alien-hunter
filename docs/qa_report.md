# XENOREACH — Adversarial QA Report

**VERDICT: FAIL (2 P0)** — the world/systems layer is genuinely solid (quests, alliances, vehicles, streaming, UI all pass real-path tests), but two ship-blockers make the shipped game read as broken the moment any character is on screen or the player swings at an enemy.

Evidence lives in `/workspace/verify/qa_*.png` (my captures), plus headless probe transcripts quoted below. All checks drove the REAL code paths (interaction.try_use, main._attack, main._offer_alliance, quest.notify_*, USE-button boarding) — no test-only shortcuts.

---

## ❌ P0-1 — Every rigged CHARACTER model renders as a ~100–240 m GIANT (player invisible, enemies/elders/boss fill the screen)

**Symptom (browser, SwiftShader + confirmed numerically in-engine — NOT a software-GL artifact):**
- The player has NO visible body at ground level — just a floating sword (`qa_after_move.png`, `crop_move`, `live_game.png` — same on the production preview). The hunter is actually rendering as a ~165 m giant: pitch the camera up and its ribbed khaki torso fills the sky (`qa_sky_up.png`, `qa_attack.png`; it is the recurring black blob in the sky of most frames, incl. `qa_land_game.png`).
- Any populated area is worse: a single skarn near spawn fills the whole viewport with a teal-banded limb (`qa_v_horse.png`); the skarn camp view is one giant blue-gray body (`qa_w_camp_b.png`); the broodmaw lair shows a skyscraper-scale boss leg (`qa_w_lair.png`).
- **Numeric proof (headless model probe — static mesh AABB vs actual bone global positions; skinned rendering follows the BONES):**

  | model | static height | bone extent (global) | verdict |
  |---|---|---|---|
  | hunter.glb (player) | 2.10 m | **202 m** | giant |
  | trader.glb (all 4 camp elders) | 1.60 m | **161 m** | giant |
  | skarn.glb | 1.70 m | **138 m** | giant |
  | gorra.glb | 2.40 m | **239 m** | giant |
  | veyth.glb | 2.00 m | **200 m** | giant |
  | mylah.glb | 1.90 m | **192 m** | giant |
  | broodmaw.glb (boss) | 3.20 m | **1121 m** | giant |
  | strider / duneback / skyray (mounts) | 2.1 / 2.6 / 1.2 m | 2.2 / 2.8 / 1.5 m | **CLEAN** |

  Live streamed enemies confirm it in the running game: `QA_LIVE_ENEMY type=skarn static_h=1.70 bone_max_h=153.6` — bones 153 m above the enemy origin.

**Root cause:** the 7 character GLBs (hunter, trader, 5 species) embed a `0.01`-scaled skeleton whose bone rest poses are authored at ×100 (cm-style) relative to their mesh nodes — the runtime `GLTFDocument.append_from_buffer` path yields sane STATIC AABBs (which is what `_attach_hero_model` / `enemy.gd` normalize against) but the skinned render follows the giant bone poses. The three MOUNT GLBs were produced with consistent units (skel_scale 1.0, bones ~2 m) and render perfectly (`qa_v_dragon.png` — the Skyray looks great), so the fix is to re-export/re-rig the 7 character models through whatever pipeline produced the mounts (or bake the unit scale into bone rests + skin binds). Gameplay logic (origins, hit ranges) is unaffected — this is purely the render — which is exactly why every numeric self-check passed while the game looks broken.

**Downstream of the same bug:** `GEquip` bone-attaches the weapon to the hand bone. Measured muzzle position: **y ≈ 106 m** → plasma bolts spawn 100 m in the sky and expire (3 s lifetime) before they can reach anything. Headless: `QA_RANGED front hit=false`, projectile tracked at `(40.3, 106.8, 133.9)` while player stood at `(35, 1.3, 76)`. **The Plasma Caster (and every ranged species weapon) can never hit** when the weapon is bone-attached. In the no-save sandbox the equip lands on the capsule-offset fallback instead (muzzle sane, but the sword visibly floats in mid-air beside nothing — every screenshot).

## ❌ P0-2 — Melee ATTACK is 180° inverted: it hits enemies BEHIND the player, never the one in front

**Symptom:** walk up to an enemy (facing it) and tap ATTACK → miss. An enemy chasing you from behind → hit.

**Empirical proof (headless, real `main._attack()` path):** player walked east (real movement code; `basis.z=(1,0,0)` = facing east by the stack's own convention):
- enemy 1.6 m IN FRONT (east): `QA_MELEE front hit=false hp 40->40` (re-confirmed at 0.75 m: still no hit)
- enemy 1.6 m BEHIND (west): `QA_MELEE behind hit=true hp 40->18`

**Root cause:** `main.gd _attack()` line ~644 uses `var fwd := -player.global_transform.basis.z`, while movement `look_at`, `enemy._face`, and `_fire_ranged` all define character facing as **+basis.z** (the comment at `_fire_ranged` even documents "characters FACE +Z … melee's legacy -basis.z half-cone above is untouched"). One-character fix: melee `fwd = +basis.z`. (The coordinator's own logic test spawns its melee target at `-basis.z`, which is why it passed — it codified the bug.)

---

## ❗ P1 issues

1. **Enemies fall through the world.** Found a live skarn at `y=-34.8` (below the kill floor) near the skarn camp: `QA_LIVE_ENEMY pos=(62.2, -34.79, 115.2)`. The player has a fall-catcher (`main._chunk_physics`, y<-30 reseat); enemies have none — a fallen quest target (m1/m4 kill-counts, m5 boss) becomes unkillable until eviction respawn. Fix: apply the same terrain-reseat to enemies.
2. **Flying rides can escape the world → total eviction.** Terrain border walls are 8 m tall; the Talon Skiff climbs to 32 m and the Skyray flies. Headless: player beyond the grid → `resident=0` — every cell (town, camps, props, enemies) evicted; only the terrain skirt + water remain. It rebuilds on return, but a player who flies over the edge watches the whole world vanish. Fix: clamp airborne vehicle XZ to the grid rect (or extend the boundary to ALT_MAX for airborne states).
3. **"Rusty Sword" (medieval template item) ships in the hunter's inventory** — visible in the HUD inventory line within seconds and listed FIRST in the PACK (`qa_pack.png`), with damage 25 that strictly BEATS the signature Wrist Blades (22) — equipping it is mechanically optimal and thematically wrong. Fix: seed `RpgState.inventory` for this world without `rusty_sword` (or re-stat/reskin it via the world `weapons` block).
4. **Boarding-seat / weapon-in-hand visual verification is blocked by P0-1** — the rider has no visible body (Skyray shows a saddle + floating sword, `qa_v_dragon.png`; `GOGI_SEAT_CONTACT` metas read 0.000). Must be re-verified visually after the rig fix.

## ⚠️ Warnings / polish (P2)

- **Chests are flat untextured yellow BoxMeshes** (`qa_w_ruins.png`, `qa_w_lair_b.png`) — the one gray-box-class placeholder left in an otherwise materials-correct world; worth a GSurf/textured pass.
- **Interact prompt overlaps HUD buttons** at 400×860: "USE > Drive Dune Skimmer" renders across the PACK/USE labels (`luma-day.png`); in missions mode the objective banner text collides with the top-left `Inv:` line (`qa_missions.png`).
- **Dev-style HUD line shipped**: `Area:c3_6 enemies 0 fps 2` reads as debug text on a consumer HUD.
- **Death is a silent full-heal respawn in place** (`main.take_damage`) — no death feedback at all; at least a vignette/flash + brief message recommended.
- **m3 (Broker an Alliance) auto-completes instantly** if the player allied any species before starting missions (the `allied_any` flag persists) — acceptable, but a fresh marker/beat is skipped.
- One headless run measured a boarded car integrating 0.00 m for 5 s; unreproducible in three follow-ups (browser drive: 28.6 m, perfectly aligned) — not filed as a bug, noting for completeness.

## ✅ What passes (real-path evidence)

- **Boot/console:** engine boots on the production preview + local export; zero SCRIPT/Parse/Uncaught errors across all runs. `verify.mjs`: packaging OK, scene-instantiation OK, **qgcheck: world winnable (144 areas)**, audio infra OK. (Note: verify.mjs's own 120 s watchdog expires before its feel probes finish in this slow container — its core PASSes are all green; the flat-tint lint it raises is a false positive: fresh materials go to fallback capsules/FX only, and enemy/hero GLBs keep their own textures.)
- **Title & modes:** portrait + landscape title screens centered and fully readable (`qa_title_portrait.png`, `qa_land_title.png`); EXPLORE and MISSIONS both start (`GOGI_MODE` logged); scene fills all four corners at 400×860 and 860×400 with HUD inside the viewport (`qa_land_game.png`).
- **Movement/camera:** WASD moves (7.1 m measured under stall conditions), right-half drag orbits yaw (0 → 1.30 rad), pitch clamps (never floor-stares, `qa_pitch_down.png`), real sky + clouds overhead.
- **Quest chain m1→m5** through real notify paths: kill-counts, relic collect, alliance flag, boss kill → all statuses advance, **victory overlay appears on broodmaw kill**, nav arrow + `OBJECTIVE Nm` shown in missions mode only, marker coords correct per quests.json.
- **Alliance loop (real proximity path):** elder registered at the skarn camp → ALLY button appears within 5 m with correct species name → `_offer_alliance()` allies + sets flags → button hides → allied member duels a hostile → striking the ally reverts the species to hostile.
- **Species powers:** skarn acid damages the player; veyth cloaks at range and decloaks on hit; gorra closes and damages; mylah heals wounded kin (all headless, real enemy code).
- **Combat feedback:** melee delta 22 hp + hit particles + species stats correct (when the cone matches — see P0-2); enemy AI damages the player unprompted.
- **Loot economy:** kills pay gold + species trophies; chest USE pays gold (0→35); potion heals; PACK opens with weapons/EQUIP/standing sections rendering cleanly (`qa_pack.png`).
- **All 7 vehicles** board via walk-up USE, reach DRIVING, move, and exit: car (28.6 m browser drive, correct camera-relative direction + nose-first away from camera, `qa_car_after.png`), tank, boat (16.4 m), plane, horse (5.3 m), bull (22.8 m), dragon (64.4 m + climbs in browser flight test). Weapon stows in the car, stays on mounts; driver restored visible on exit.
- **World richness:** 144 cells / 12×12, 30 road cells (terrain-following asphalt with dashed centerlines — reads great from the air, `qa_v_dragon_air.png`), per-cell ground presets + scatter everywhere, 25 parametric structures with real materials + emissive sign lights at camps, 7 landmarks (crashed ship, ruin gate, hive spire), 12 chests, 35 enemies across 5 species, 4 elder camps, western sea (swim verified in deep water; wade at shallow), bioluminescent motes; **day and night both readable** (`luma-day.png` / `luma-night.png` — night keeps geometry + flora legible, day doesn't clip).
- **Boundary on foot:** invisible border walls hold (x pinned at 0.9 pushing west for 5 s); fall-catcher reseats the player.
- **Persistence:** full save round-trip against the real Supabase table via native HTTPRequest (gold 4242 restored into a fresh SaveSystem).
- **Meshy mandate:** every character role (player, elders, all species, boss) + all 3 mounts are Meshy models; KayKit rigs are only the clip-retarget fallback library. ✓
- **Audio:** AudioManager + bus layout + 13 baked tracks (music, alien ambient, rain/thunder/wind, combat SFX) wired to attack/death/door/pickup + mode start.

## Could not verify (sandbox limits)

Real-GPU fidelity & frame rate (SwiftShader ~1-2 fps here); actual audio playback; touch-gesture feel; cross-device save UX in the browser (sandbox TLS blocks supabase in Chromium — native round-trip verified instead, as disclosed); storm/rain phase visuals on the live clock (day/night verified via the deterministic `gogiSetTime` hook).

## Suggested fix order

1. Re-export/re-rig the 7 character GLBs with unit-consistent skeletons (match the mounts' pipeline); re-verify with the bone-vs-AABB probe (a one-liner: bone extent must ≈ static AABB), then re-shoot player back/face, enemy engage, boarding-seat and weapon-in-hand frames.
2. Flip the melee cone to `+basis.z` in `main._attack`.
3. Enemy fall-catcher; airborne grid clamp; drop `rusty_sword` from the seed inventory; chest material; prompt/HUD overlap nudges.
