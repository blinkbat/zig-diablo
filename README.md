# zig-diablo

A Diablo-inspired action RPG prototype built in [Zig](https://ziglang.org/) with [raylib](https://www.raylib.com/) via [raylib-zig](https://github.com/Not-Nik/raylib-zig).

## Features

- Real-time isometric-style combat prototype
- Authored campaign maps (`maps/*.map`) loaded in lexicographic order
- In-game/editor tooling for map/content workflows
- Dynamic lighting + fog/shadow pipeline
- UI/HUD and stat systems
- Cross-file gameplay modules for monsters, loot, projectiles, particles, and player progression

## Tech Stack

- **Language:** Zig
- **Rendering/Input/UI bindings:** raylib + raygui (through `raylib-zig`)
- **Build system:** Zig build (`build.zig`, `build.zig.zon`)

## Requirements

- Zig **0.14.1** (minimum version declared in `build.zig.zon`)
- A desktop platform supported by raylib

> Note: This repository includes Windows helper scripts and may be primarily developed on Windows.

## Getting Started

### 1) Clone

```bash
git clone https://github.com/blinkbat/zig-diablo.git
cd zig-diablo
```

### 2) Build

Standard Zig flow:

```bash
zig build
```

Run directly with Zig:

```bash
zig build run
```

### 3) Windows helper scripts

The repository includes convenience scripts:

- `build.cmd`
- `build-release.cmd`
- `run.cmd`
- `run.ps1`
- `run-demo.cmd`
- `run-demo.ps1`
- `run-demo2.cmd`

Use these if your local setup expects the same toolchain/scripted flow as the project author.

## Repository Layout

- `src/` — game and engine code
  - `main.zig` — application entry point
  - `game.zig` — core game loop/state
  - `editor.zig` — world/editor logic
  - `map.zig`, `world.zig` — map loading and world construction
  - `player.zig`, `monster.zig`, `loot.zig`, `projectile.zig`, `particles.zig` — gameplay entities/systems
  - `torchlight.zig`, `fog.zig`, `scenemesh.zig`, `camera.zig` — rendering/lighting/camera pipeline
  - `hudx.zig`, `ui.zig`, `stats.zig`, `theme.zig` — HUD/UI/stats/theming
- `maps/` — authored map files (campaign content)
- `assets/` — static assets (font + license text)
- `build.zig` / `build.zig.zon` — build/package configuration

## Development Notes

- Maps are authored data (`maps/*.map`) and are central to world generation.
- `src/demo2.zig` is used as a reference demo in this codebase.
- The project emphasizes fixed-capacity/per-frame-friendly patterns in hot gameplay paths.

## License

No license file is currently present in the repository.

If you intend to distribute or accept external contributions, consider adding a license (e.g. MIT/Apache-2.0) and contribution guidelines.