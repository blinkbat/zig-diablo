# AGENTS.md — zig-diablo

Ground rules for anyone (human or agent) working in this repo. Keep this file lean.

## Build & verify
- `zig` is NOT on PATH. Build with `build.cmd` (debug) or `build-release.cmd`; the
  toolchain is vendored at `..\.zigtoolchain\zig-x86_64-windows-0.14.1\zig.exe`.
- Verify rendering changes by RUNNING `zig-out\bin\zig-diablo.exe --gameshot` and
  looking at the 8 PNGs in `shots\` (spawn/rampart, family portrait, portal, stat
  sheet, menu, death, victory, editor). Don't claim a visual change works without a shot.
- Never write screenshots into the repo tree except `shots\` (gitignored).
- Don't commit, push, or create branches unless explicitly asked.

## Hard invariants (break these and the game silently rots)
- `src/demo2.zig` is the FROZEN lighting reference. Never edit it.
- The world is AUTHORED: `maps/*.map` files are the campaign (lexicographic order).
  No runtime procgen — `map.toWorld()` is the only World constructor. The map
  format requires a `version:` header; unknown keys must stay load ERRORS.
- The shadow pipeline is ONE overhead camera. Constraints that follow:
  - light height − `SHADOW_CLIP_NEAR` must clear the tallest caster;
  - terrain is a single-valued heightfield (ledges/ramps) — nothing walkable may
    ever be UNDER other geometry (that requires a cubemap rewrite; owner declined).
- Dynamic bodies (monsters/loot) are culled at the frame's LIT torch radius and
  must never render in the fog-of-war "seen" band; emissive things (eyes, bolts,
  torch, particles) draw AFTER `endScene` and are exempt.
- The scene shader gammas output (`pow 1/2.2`): dark albedos lift hard. Rich dark
  colors must START near-black (see tree canopy note in scenemesh.zig).

## UI & editor conventions
- All UI text goes through `hudx.text/textW` (IM Fell font, x-height compensated).
  Never call `rl.drawText`/`rl.measureText` directly in UI code — layout drifts.
- Editor interaction follows the crawler-editor grammar: LMB paints, RMB-click =
  context menu, RMB-drag = pan (4 px threshold), RMB never deletes; erase is a
  per-layer brush. Every mutation must bank an undo snapshot (pre-mutation).
- Editor widgets live in `src/ui.zig`; `Ctx.anyHot` gates world clicks next frame.

## Code style
- Fixed-capacity arrays over allocators in per-frame paths (see ProjList,
  Particles). Follow the existing comment voice: explain constraints and WHY,
  not what the next line does.
- Gameplay reach/telegraph math must share one source (e.g. `meleeReach`) so
  drawn rings never lie about hitboxes.
