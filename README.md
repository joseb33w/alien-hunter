# Xenoreach — open-world alien hunter (mobile web)

You are a Predator-style apex hunter stranded on a bioluminescent alien world.
Third-person, free-roam, mission-driven — built with Godot 4.6.3 (Compatibility renderer,
single-threaded web export) on the Gogi RPG streaming template, with a Supabase backend.

**Play:** https://preview.myapping.com/cloud-buzjpf9z8on0ylyzwny3/

## How to play
- **Left half of the screen:** drag to move (WASD on desktop). **Right half:** drag to look.
- **Title screen:** EXPLORE (free roam) or MISSIONS (a 5-mission hunt chain with an on-screen objective arrow).
- **ATTACK** fires your equipped weapon (wrist blades melee / plasma caster ranged — auto-aim cone).
- **PACK** opens your gear: switch weapons, view trophies + treasure, check species standing.
- **USE** interacts: open chests, talk to elders, board rides.
- **ALLY** appears near a hostile species' camp elder — press it to befriend that species; its
  hunters then fight at your side (striking an ally betrays the pact).

## The five species
| Species | Power |
|---|---|
| Skarn | spits corrosive acid globs |
| Veyth | light-bend cloak until it closes in |
| Gorra | crushing charge rush |
| Mylah | pulse-heals its kin (or you, when allied) |
| Broodmaw | the boss — huge, acid + slam (goal of the final mission) |

Every kill drops treasure shards + a species trophy. Species weapons wait in camp chests.

## Getting around
- **Mounts:** Razorstrider (fast), Duneback (heavy), Skyray (flying — hold the stick to climb,
  release to glide down and land). Walk up + USE to ride.
- **Vehicles:** Dune Skimmer buggy and Ravager Crawler tank — full turning AND reverse
  (pull the stick back).
- **Ships:** the Talon Skiff flies (takeoff past ~9 m/s, 32 m ceiling); the Tide Skiff sails the western sea.
- Deep water is swimmable on foot.

## World
A 12x12-cell seamless streamed chunk world (~192 m across): crash-site plains, a glowing
forest, dune badlands, ancient ruins, four species camps, a western sea, connected roads, and
the Broodmaw's lair. Full day -> sunset -> night -> dawn cycle with rain and lightning storms.

## Backend (Supabase)
Progress persists per device (unguessable UUID key in localStorage) to
`usr_nmexs7bytxq2_alien_hunter_saves` — inventory, equipped weapon, gold/XP, mission
progress, per-species alliance state, and position. RLS enabled; the anon role can only
select/insert/update.

## Development
- `godot --headless --path . --import` then `--export-release "Web" out/index.html`
- `world.json` + `quests.json` are loose data files served next to `index.html` (not packed).
- Meshy-generated characters/mounts/landmarks stream at runtime from R2 under
  `/cloud-buzjpf9z8on0ylyzwny3/models/`.

Assets: KayKit / Kenney / Quaternius CC0 kits, Meshy-generated characters, CC0 audio.
