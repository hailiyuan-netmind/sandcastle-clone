# Project status and research agenda

Last updated: 2026-08-17. Companion to the README; this file tracks where the
project stands, what is broken, and what the next research session should dig
into.

## Where the project stands

Four layers, all working, all in this repo:

1. **2D web game** (`index.html`) - falling-sand cellular automaton, complete
   game loop, playable on GitHub Pages
2. **3D web prototype** (`3d.html`) - heightfield sand + pipe-model shallow
   water in raw WebGL2
3. **Godot build** (`godot/`) - the real base: GPU compute simulation
   (384x384 field, water + sand passes), sculpting tools with an atomic sand
   budget, flag/tide/game-over loop, procedural audio, diorama framing,
   refraction water with lace foam, caustics
4. **MPM layer** - lab scene (`godot/mpm.tscn`, 100K coupled water+sand
   particles, in-shader 3x3 SVD) plus an in-game active zone coupled to the
   heightfield (erosion spawns grains, settled grains deposit back)

## Known issues

- **Blue particle flood after digging into the waterline** (user-reported,
  reproduced): water rushing into a fresh trench spikes `flow = flux /
  max(0.05, depth)` while depth crosses the 0.10 spawn gate; if a surge is
  active, hundreds of cells qualify simultaneously and the spray queue dumps
  up to 512 particles per frame. Candidate fixes: per-cell spawn cooldown
  texture; use the accumulated foam channel (sustained churn) instead of
  instantaneous flow as the spawn criterion; suppress spawning inside the
  active brush radius for a second after tool use.
- **Offscreen fps numbers are noisy** (±8 fps between identical runs) and the
  demo script builds different wall heights depending on frame rate (frame
  -driven script, dt-driven physics). Perf conclusions need in-game feel or
  wall-clock timing, not `Engine.get_frames_per_second()` snapshots.
- PCSS penumbra shadows (`light_angular_distance > 0`) are very expensive
  once background pixels are geometry instead of sky - already switched to
  fixed shadow blur, keep this in mind for future props.

## Next build steps (agreed priority)

1. Sculpting tools (V-trench, flat trowel, press molds) - the biggest
   gameplay gap vs the original; needs a smooth-sand surface state
2. Ecology scatter (corals, shrubs, pebbles via MultiMesh) and beach props
3. Soft particle rendering (stretched quads, distance fade)
4. Parameterized beach generator (layout / sand type / waves / seed) - our
   terrain is already procedural, expose the knobs
5. True SSR water reflections; breaking-wave curl geometry (hard)

## Research agenda for the next session

Goal: mine public traces of how the original does it, and collect open-source
implementations worth porting.

**The developer's own public material** (closed source, but he shows a lot):

- Fabien Weibel / Bubblebird Studio - X account posts frequent devlog clips
  of Sandcastle's sand and water behavior; worth cataloging frame by frame
- His pre-gamedev career is VFX sand/fluid simulation animation shorts
  (YouTube/Vimeo); the visual language of Sandcastle descends directly from
  them
- Interviews and previews: 80.lv articles, indiegame.com preview; his studio
  site bubblebirdstudio.com and itch.io page (Haven Park was his previous
  game)
- Steam page facts already gathered: sandbox-diorama framing, beach
  generator (layout/format/sand type/waves/seed), 10 environments, tool-based
  sculpting with crisp trench/mold marks, quest cards

**Open-source references to evaluate**:

- Taichi MPM examples and taichi_elements (already prototyped here, see
  `research/`)
- sandspiel / Noita GDC talk - falling-sand engineering
- Ten Minute Physics (Matthias Muller) - FLIP water, PBD
- Sebastian Lague fluid sim; GPU Gems heightfield water chapters
- Godot-specific: godot-ocean-waves style FFT water repos, terrain clipmap
  techniques, MultiMesh scatter systems

## Repo

https://github.com/hailiyuan-netmind/sandcastle-clone (public, MIT).
Play links and per-layer docs in the README.
