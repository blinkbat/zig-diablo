const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const tl = @import("torchlight.zig");
const world = @import("world.zig");
const mapmod = @import("map.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
const scenemesh = @import("scenemesh.zig");
const editor = @import("editor.zig");
const fogmod = @import("fog.zig");
const playermod = @import("player.zig");
const loot = @import("loot.zig");
const cameramod = @import("camera.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");
const rumble = @import("rumble.zig");
const particles = @import("particles.zig");

const Monster = monster.Monster;
const Projectile = projectile.Projectile;
const Player = playermod.Player;
const LootDrop = loot.LootDrop;
const CamRig = cameramod.CamRig;

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const sinf = mathx.sinf;
const cosf = mathx.cosf;
const distXZ = mathx.distXZ;
const dist2XZ = mathx.dist2XZ;
const dirXZ = mathx.dirXZ;
const lenXZ = mathx.lenXZ;
const clampF = mathx.clampF;
const maxF = mathx.maxF;

const alloc = std.heap.c_allocator;

const MAX_MONSTERS = 128;
const CAST_RATE = 0.7; // firebolt cooldown (seconds)
const CRIT_CHANCE = 0.15;
const CRIT_MULT = 2.0;

// Scuffed-earth dust kicked up by footsteps and dodges — one tint (alpha varies per
// use) so the two effects read as the same dry road.
const DUST_COLOR = rgba(200, 172, 132, 255);

// Torch tuning. The light is anchored to the CARRIED torch: its XZ tracks the flame
// in the hero's off-hand (smoothed — see torchXZ), so shadows fall away from the
// torch side and swing around as the hero turns, instead of radiating from a lamp
// floating over the hero's head. Height is a hard trade: lower = longer, more
// lantern-dramatic body shadows and grazing floor light, but the overhead shadow
// camera's cone must stay under its 150-degree FOV clamp (2*atan(12*1.3/4.5) =
// 148) and TORCH_HEIGHT - SHADOW_CLIP_NEAR must clear a zombie/brute head (~3.9)
// so they keep casting. 4.5 is the floor of that envelope; only the boss's crown
// (~4.9) pokes above it, which reads as campfire uplighting on the champion.
const TORCH_HEIGHT = 4.5;
const TORCH_RADIUS = 12.0;

// The hero is drawn scaled up about his feet by this factor (uniform, so normals
// stay valid untransformed). 1.22 also closes the old gap between the drawn torso
// (0.42) and the actual collision radius (playermod.radius 0.55) — the body you
// see finally fills the hitbox you play.
const HERO_SCALE = 1.22;

// The off-hand torch grip: ONE set of offsets shared by the drawn stick + flame
// (hero-local frame) and torchFlameWorld (the world anchor for the light and
// embers), so the visual flame and the light source can never drift apart.
const TORCH_GRIP_RIGHT = 0.45;
const TORCH_GRIP_FWD = 0.05;
const TORCH_FLAME_Y = 1.64; // flame-heart height in the hero's ground-local frame

// A live player fireball is its own moving light: a warm pool that follows the bolt
// and lights (+ shadows) whatever it flies past, even out beyond the torch radius.
// Modeled overhead like the torch so its downward shadow map stays well-oriented.
const FIRE_HEIGHT = 3.5;
const FIRE_RADIUS = 7.0;
// The vision radius that gates targeting / health bars / popups — a little past the
// torch's lit disc so a foe right at the edge can still be hovered and engaged. Body
// DRAWING is gated tighter, at TORCH_RADIUS itself (see bodyVisible), so nothing dynamic
// bleeds into the fog-of-war "seen" band beyond the light.
const CULL = TORCH_RADIUS + 3;

pub const DAMAGE_FLASH_DUR = 0.4;
pub const TOAST_DUR = 2.5;

// How long the area-name banner holds before fading (seconds). Level-up reuses the
// banner with its own shorter hold.
const AREA_BANNER_DUR = 3.5;
const LEVELUP_BANNER_DUR = 2.2;

// Fixed-capacity projectile pool (arrows + firebolts); no allocator needed.
const ProjList = struct {
    buf: [256]Projectile = undefined,
    count: usize = 0,
    fn add(self: *ProjList, p: Projectile) void {
        if (self.count < self.buf.len) {
            self.buf[self.count] = p;
            self.count += 1;
        }
    }
    fn items(self: *ProjList) []Projectile {
        return self.buf[0..self.count];
    }
};

// A fixed-capacity, self-contained transient text field: format into an inline buffer
// with a countdown timer. The toast and the area banner share this so neither re-rolls
// the overflow-safe bufPrintZ + buffer/len bookkeeping.
fn TextField(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = [_]u8{0} ** cap,
        len: usize = 0,
        time: f32 = 0,

        const Self = @This();

        fn set(self: *Self, dur: f32, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrintZ(&self.buf, fmt, args) catch blk: {
                self.buf[0] = 0; // keep the sentinel valid if the format overflowed
                break :blk self.buf[0..0 :0];
            };
            self.len = s.len;
            self.time = dur;
        }
        fn tick(self: *Self, dt: f32) void {
            if (self.time > 0) self.time -= dt;
        }
        pub fn active(self: *const Self) bool {
            return self.time > 0 and self.len > 0;
        }
        pub fn text(self: *const Self) [:0]const u8 {
            return self.buf[0..self.len :0];
        }
    };
}

pub const Scene = enum { menu, playing, dead, victory, editor };
pub const MenuMode = enum { root, options };
pub const DisplayMode = enum { windowed, borderless, fullscreen };

pub const menuRootItems = [_][:0]const u8{ "Adventure", "Editor", "Options", "Quit" };

// "Options" is index 2 of menuRootItems: entering the options screen and every
// return-from-options lands the cursor here, so the position lives in one place.
pub const MENU_OPTIONS_IDX = 2;
// The options screen has two rows — [display-mode cycler, Back] (see hudx) — and
// key-nav wrap must agree with that count.
pub const MENU_OPTIONS_COUNT = 2;

// Switch the window's display mode, unwinding whatever mode is active first so
// the raylib toggles never stack (each toggle is its own on/off latch).
fn setDisplayMode(g: *Game, want: DisplayMode) void {
    if (g.displayMode == want) return;
    switch (g.displayMode) {
        .borderless => rl.toggleBorderlessWindowed(),
        .fullscreen => rl.toggleFullscreen(),
        .windowed => {},
    }
    switch (want) {
        .borderless => rl.toggleBorderlessWindowed(),
        .fullscreen => rl.toggleFullscreen(),
        .windowed => {},
    }
    g.displayMode = want;
}

pub fn cycleDisplayMode(g: *Game, fwd: bool) void {
    const n: i32 = @typeInfo(DisplayMode).@"enum".fields.len; // add a mode and the cycle covers it
    const cur: i32 = @intFromEnum(g.displayMode);
    const next: DisplayMode = @enumFromInt(@mod(cur + (if (fwd) @as(i32, 1) else -1) + n, n));
    setDisplayMode(g, next);
}

// Activate a menu item (shared by keyboard Enter and mouse click in hudx).
pub fn menuActivate(g: *Game, idx: i32) void {
    if (g.menuMode == .options) {
        switch (idx) {
            0 => cycleDisplayMode(g, true),
            else => {
                g.menuMode = .root;
                g.menuSel = MENU_OPTIONS_IDX;
            },
        }
        return;
    }
    switch (idx) {
        0 => g.startRun(),
        1 => editor.enter(g),
        MENU_OPTIONS_IDX => {
            g.menuMode = .options;
            g.menuSel = 0;
        },
        else => g.quit = true,
    }
}

// A melee monster's true reach: its attack range, plus the target's radius, plus a
// small lunge. The strike check and the drawn telegraph ring MUST use this same
// formula so that standing just outside the ring is genuinely safe.
const MELEE_LUNGE = 0.35;
fn meleeReach(atkRange: f32, targetRadius: f32) f32 {
    return atkRange + targetRadius + MELEE_LUNGE;
}

// The hero's own strike reach against a target: attack range plus the target's radius.
// One helper so the chase-stop distance and the hit check can't drift apart.
fn playerReach(atkRange: f32, targetRadius: f32) f32 {
    return atkRange + targetRadius;
}

// Max vertical gap at which two bodies count as "on comparable ground" for melee:
// a strike (either direction) and a monster's decision to wind up all read this one
// rule, so nobody can swing across a cliff/rampart edge. One source keeps the three
// combat gates in lockstep. (Comfortably above world.STEP_MAX so a single step up a
// ramp is still within reach.)
const SAME_GROUND_DY = 1.0;

// Low-poly sphere. raylib's drawSphere defaults to 16x16 and regenerates on the CPU
// with per-vertex trig on every call — the scene is drawn twice a frame (shadow depth
// pass + main pass). Under a dark torch an 8x8 ball is indistinguishable at ~1/4 cost.
fn sphere(pos: rl.Vector3, r: f32, col: rl.Color) void {
    rl.drawSphereEx(pos, r, 8, 8, col);
}

// Scale the model-view stack up about the hero's feet, so every hero draw call
// (body + FX, in every pass) renders HERO_SCALE bigger without touching its math.
// The final translate carries base.y, lifting the whole (ground-relative) body
// onto whatever terrain the hero stands on. Uniform scale only: rlgl doesn't
// re-transform normals, which is exactly correct for a pure uniform scale.
fn beginHeroScale(base: rl.Vector3) void {
    rl.gl.rlPushMatrix();
    rl.gl.rlTranslatef(base.x, base.y, base.z);
    rl.gl.rlScalef(HERO_SCALE, HERO_SCALE, HERO_SCALE);
    rl.gl.rlTranslatef(-base.x, 0, -base.z);
}

// The carried torch's flame position in the world: off-hand side of the hero, at
// flame height above his ground, in the SCALED body's frame. One source of truth
// shared by the ember spitter and the LIGHT itself (the light's XZ anchors here —
// see Game.torchXZ); the drawn flame lands here too via the beginHeroScale wrap.
fn torchFlameWorld(p: *const Player) rl.Vector3 {
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);
    return v3(
        p.Pos.x + (-right.x * TORCH_GRIP_RIGHT + f.x * TORCH_GRIP_FWD) * HERO_SCALE,
        p.Pos.y + TORCH_FLAME_Y * HERO_SCALE,
        p.Pos.z + (-right.z * TORCH_GRIP_RIGHT + f.z * TORCH_GRIP_FWD) * HERO_SCALE,
    );
}

// ---- Game state ----

pub const Game = struct {
    scene: Scene = .menu,
    rng: mathx.Rng,
    torch: tl.Torch,
    sceneMesh: scenemesh.SceneMesh,
    fog: fogmod.Fog,
    w: world.World,
    // The authored campaign: maps/*.map in lexicographic order. `map` is the
    // CURRENT area's parsed file — the world, monster spawns, and displayed
    // area name all come from it.
    map: mapmod.Map,
    mapPaths: [mapmod.MAX_MAPS][96]u8 = undefined,
    mapPathLens: [mapmod.MAX_MAPS]usize = undefined,
    mapCount: usize = 0,
    areaIndex: usize = 0,
    lastArea: usize,
    ed: editor.Editor = .{},
    playtest: bool = false, // playing FROM the editor: all exits lead back to it

    // Start menu state + display mode.
    menuMode: MenuMode = .root,
    menuSel: i32 = 0,
    quit: bool = false,
    displayMode: DisplayMode = .windowed,

    p: Player,
    monsters: [MAX_MONSTERS]Monster = undefined,
    monsterCount: usize = 0,
    nextID: i32 = 0,
    projs: ProjList = .{},
    lootList: std.ArrayList(LootDrop),

    rig: CamRig,

    // Per-frame input cache.
    mouseGround: rl.Vector3 = mathx.zero3,
    kbMove: rl.Vector3 = mathx.zero3,
    hoverMonster: i32 = -1, // monster id (NOT an array index): stays valid across the
    // same-frame corpse compaction in updateDeaths, so the highlight can't slip onto the
    // wrong monster between updateAim setting it and the HUD reading it.

    // Presentation timers + transient text.
    damageFlash: f32 = 0,
    shake: f32 = 0,
    banner: TextField(96) = .{},
    toast: TextField(96) = .{},

    paused: bool = false,
    elapsed: f32 = 0,
    kills: i32 = 0,
    rumble: rumble.Rumble = .{},
    parts: particles.Particles = .{},
    portalPuff: f32 = 0, // countdown to the next portal mote
    stepPuff: f32 = 0, // countdown to the next footstep dust kick
    // Where the LIGHT is this frame: the carried flame's ground point, smoothed so
    // shadows swing around a turn instead of snapping when Facing flips.
    torchXZ: rl.Vector3 = mathx.zero3,

    pub fn init(seed: u64) !Game {
        var torch = try tl.Torch.init();
        errdefer torch.deinit();
        const rng = mathx.Rng.init(seed);

        var g = Game{
            .rng = rng,
            .torch = torch,
            .sceneMesh = undefined,
            .fog = fogmod.Fog.init(),
            .w = undefined,
            .map = undefined,
            .lastArea = 0,
            .p = playermod.newPlayer(mathx.zero3),
            .lootList = std.ArrayList(LootDrop).init(alloc),
            .rig = cameramod.newCamRig(),
        };
        g.mapCount = mapmod.listCampaign(&g.mapPaths, &g.mapPathLens);
        g.lastArea = if (g.mapCount > 0) g.mapCount - 1 else 0;
        g.map = g.loadMapAt(0);
        g.w = mapmod.toWorld(&g.map, g.lastArea == 0);
        g.sceneMesh = scenemesh.SceneMesh.init(&g.w, g.torch.scene, g.torch.depthShader);
        g.fog.reset(g.w.HalfW, g.w.HalfD);
        g.p = playermod.newPlayer(g.map.spawn);
        g.areaIndex = 0;
        g.torch.setLightColor(g.map.light);
        g.spawnPacks();
        g.rig.snap(g.p.Pos);
        g.torchXZ = torchFlameWorld(&g.p);
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.map.name.slice()});
        return g;
    }

    // Load the idx-th campaign map file; a missing folder or a corrupt file falls
    // back to the built-in empty field so the game always boots.
    pub fn loadMapAt(g: *Game, idx: usize) mapmod.Map {
        if (g.mapCount == 0) return mapmod.defaultMap();
        const i = @min(idx, g.mapCount - 1);
        return mapmod.load(g.mapPaths[i][0..g.mapPathLens[i]]) catch mapmod.defaultMap();
    }

    // Where the editor saves the current area's map.
    pub fn currentMapPath(g: *Game) []const u8 {
        if (g.mapCount == 0) return mapmod.dir ++ "/01_custom" ++ mapmod.ext;
        const i = @min(g.areaIndex, g.mapCount - 1);
        return g.mapPaths[i][0..g.mapPathLens[i]];
    }

    pub fn deinit(g: *Game) void {
        g.sceneMesh.deinit();
        g.fog.deinit();
        g.torch.deinit();
        g.lootList.deinit();
        hudx.unloadOrbRT();
    }

    // startRun resets a finished/dead game back to area 0 with a fresh hero.
    pub fn startRun(g: *Game) void {
        g.playtest = false;
        g.paused = false; // a pause from the previous run must not freeze this one
        g.p = playermod.newPlayer(mathx.zero3);
        g.kills = 0;
        g.elapsed = 0;
        g.enterArea(0);
        g.scene = .playing;
    }

    // enterArea loads the given campaign map, rebuilds the world, and spawns packs.
    pub fn enterArea(g: *Game, idx: usize) void {
        g.areaIndex = if (idx > g.lastArea) g.lastArea else idx;
        g.map = g.loadMapAt(g.areaIndex);
        g.w = mapmod.toWorld(&g.map, g.areaIndex == g.lastArea);
        g.torch.setLightColor(g.map.light); // each floor gets its own night
        g.sceneMesh.rebuild(&g.w);
        g.fog.reset(g.w.HalfW, g.w.HalfD); // each area is a fresh layout: forget the old exploration
        g.fog.sync(); // upload the cleared grid now: a restart from dead/victory draws
        // this frame WITHOUT running updatePlaying, so it would otherwise render the new
        // area against the previous area's still-resident fog mask for one frame.
        g.monsterCount = 0;
        g.projs.count = 0;
        g.lootList.clearRetainingCapacity();
        g.parts.clear(); // stray sparks must not carry across the portal
        g.spawnPacks();
        g.p.Pos = g.map.spawn;
        g.p.hasMoveTarget = false;
        g.p.targetMonster = -1;
        g.p.HP = g.p.MaxHP;
        g.p.Mana = g.p.MaxMana;
        g.rig.snap(g.p.Pos);
        g.torchXZ = torchFlameWorld(&g.p); // snap the light with the teleport
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.map.name.slice()});
        g.setToast("", .{});
    }

    // spawnPacks deploys the map's authored packs (members jittered around each
    // pack's anchor) plus the area champion at its authored post. Difficulty tier
    // is the campaign position — map 3 hits like old area 3.
    fn spawnPacks(g: *Game) void {
        const tier: i32 = @intCast(g.areaIndex);
        for (g.map.packList()) |pk| {
            var i: i32 = 0;
            while (i < pk.count) : (i += 1) {
                g.spawn(monster.makeMonster(pk.kind, tier, &g.rng, g.randomOpenTileNear(v3(pk.x, 0, pk.z), 5)));
            }
        }
        g.spawn(monster.makeBoss(tier, g.map.boss.slice(), &g.rng, g.randomOpenTileNear(g.map.bossPos, 3)));
    }

    fn spawn(g: *Game, m_in: Monster) void {
        if (g.monsterCount >= g.monsters.len) return;
        var m = m_in;
        m.id = g.nextID;
        g.nextID += 1;
        g.monsters[g.monsterCount] = m;
        g.monsterCount += 1;
    }

    pub fn liveMonsters(g: *Game) []Monster {
        return g.monsters[0..g.monsterCount];
    }

    // monsterByID returns a pointer to the monster with the given id, or null.
    pub fn monsterByID(g: *Game, id: i32) ?*Monster {
        if (id < 0) return null;
        for (g.liveMonsters()) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    fn randomOpenTileNear(g: *Game, center: rl.Vector3, spread: f32) rl.Vector3 {
        var attempt: i32 = 0;
        while (attempt < 40) : (attempt += 1) {
            const p = mathx.ground(center.x + (g.rng.float() * 2 - 1) * spread, center.z + (g.rng.float() * 2 - 1) * spread);
            if (g.w.onFeature(p.x, p.z)) continue;
            if (!g.w.blocked(p, 0.8)) return p;
        }
        return center;
    }

    // inVision: within the torch's lit disc. Beyond it the world is black, so the hero
    // can't target, and health bars / popups there would float in darkness.
    pub fn inVision(g: *const Game, p: rl.Vector3) bool {
        return dist2XZ(p, g.p.Pos) <= CULL * CULL; // squared: pure threshold, called per monster/frame
    }

    pub fn objectCount(g: *Game) usize {
        return g.monsterCount + g.projs.count + g.lootList.items.len;
    }

    pub fn remainingMonsters(g: *Game) i32 {
        var n: i32 = 0;
        for (g.liveMonsters()) |*m| {
            if (m.alive()) n += 1;
        }
        return n;
    }

    pub fn setToast(g: *Game, comptime fmt: []const u8, args: anytype) void {
        g.toast.set(TOAST_DUR, fmt, args);
    }
    pub fn setBanner(g: *Game, dur: f32, comptime fmt: []const u8, args: anytype) void {
        g.banner.set(dur, fmt, args);
    }

};

// ---- Simulation ----

// updatePlaying advances the whole simulation by dt while in the playing scene.
fn updatePlaying(g: *Game, dt_in: f32) void {
    // Clamp dt so a hitch can't tunnel entities through walls.
    var dt = dt_in;
    if (dt > 0.05) dt = 0.05;

    if (rl.isKeyPressed(.p)) g.paused = !g.paused;
    if (g.paused) return;

    updateAim(g);
    handleInput(g);
    handleGamepad(g);
    updateTimers(g, dt);

    updatePlayerMovement(g, dt);
    updatePlayerAttack(g);

    for (g.liveMonsters()) |*m| {
        if (m.dying) continue;
        if (m.alive()) updateMonster(g, m, dt);
    }
    separateMonsters(g);
    updateProjectiles(g, dt);
    updateLoot(g, dt);
    updateDeaths(g, dt);
    updatePortal(g);
    updateAmbientFX(g, dt);
    g.parts.update(dt);

    g.rig.follow(g.p.Pos, dt);

    // Ease the light toward the carried flame: turning swings the shadows around
    // the hero over a few frames instead of snapping them when Facing flips.
    const flame = torchFlameWorld(&g.p);
    const lk = 1 - @exp(-dt * 9.0);
    g.torchXZ = v3(g.torchXZ.x + (flame.x - g.torchXZ.x) * lk, 0, g.torchXZ.z + (flame.z - g.torchXZ.z) * lk);

    // Fog of war: the torch reveals the ground it sweeps (kept as a monotonic memory),
    // then upload the mask if it changed this frame, before drawWorld samples it.
    g.fog.reveal(g.p.Pos, TORCH_RADIUS);
    g.fog.sync();
}

fn updateTimers(g: *Game, dt: f32) void {
    const p = &g.p;
    if (p.atkCD > 0) p.atkCD -= dt;
    if (p.castCD > 0) p.castCD -= dt;
    if (p.rollTimer > 0) p.rollTimer -= dt;
    if (p.rollCD > 0) p.rollCD -= dt;
    if (p.iframe > 0) p.iframe -= dt;
    if (p.swing > 0) p.swing -= dt;
    if (p.hitFlash > 0) p.hitFlash -= dt;
    if (g.damageFlash > 0) g.damageFlash -= dt;
    if (g.shake > 0) g.shake -= dt;
    g.banner.tick(dt);
    g.toast.tick(dt);
    p.regen(dt);
}

// ---- Input ----

// The screen-bottom band occupied by the HUD; clicks there don't move the hero.
// Owned by hudx (which draws the HUD) so the reserve tracks the real layout height.
const hudReserve = hudx.bottomBandHeight;

fn handleInput(g: *Game) void {
    const p = &g.p;

    // Zoom with the mouse wheel.
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) g.rig.addZoom(wheel);

    // Potions.
    if (rl.isKeyPressed(.one)) useHealthPotion(g);
    if (rl.isKeyPressed(.two)) useManaPotion(g);

    // Keyboard movement (WASD / arrows) takes precedence over click-to-move.
    var kb = mathx.zero3;
    if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) kb.z -= 1;
    if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) kb.z += 1;
    if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) kb.x -= 1;
    if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) kb.x += 1;
    const kbLen = lenXZ(kb);
    if (kbLen > 0) {
        g.kbMove = v3(kb.x / kbLen, 0, kb.z / kbLen);
        p.hasMoveTarget = false;
        p.targetMonster = -1;
    } else {
        g.kbMove = mathx.zero3;
    }

    // Dodge roll: roll in the movement direction, else toward the cursor.
    if (rl.isKeyPressed(.space)) {
        var dir = g.kbMove;
        if (lenXZ(dir) < 1e-3) dir = dirXZ(p.Pos, g.mouseGround);
        doDodge(g, dir);
    }

    const mouse = rl.getMousePosition();
    const overHUD = mouse.y > @as(f32, @floatFromInt(rl.getScreenHeight() - hudReserve));

    // Left mouse: walk to point, or chase+attack the hovered monster.
    if (rl.isMouseButtonDown(.left) and !overHUD and lenXZ(g.kbMove) == 0 and !p.rolling()) {
        const hm = g.monsterByID(g.hoverMonster);
        if (hm != null and hm.?.alive()) {
            p.targetMonster = hm.?.id;
            p.hasMoveTarget = false;
        } else {
            p.targetMonster = -1;
            p.moveTarget = g.mouseGround;
            p.hasMoveTarget = true;
        }
    }

    // Right mouse: cast Firebolt toward the cursor.
    if (rl.isMouseButtonDown(.right) and !overHUD and !p.rolling()) {
        castFirebolt(g);
    }
}

fn castFirebolt(g: *Game) void {
    const p = &g.p;
    if (p.castCD > 0 or p.Mana < p.spellCost) {
        if (p.Mana < p.spellCost) g.setToast("Not enough mana", .{});
        return;
    }
    var dir = dirXZ(p.Pos, g.mouseGround);
    if (lenXZ(dir) < 1e-4) dir = p.Facing;
    p.Facing = dir;
    p.Mana -= p.spellCost;
    p.castCD = CAST_RATE;
    const dmg = p.spellDmg + @as(f32, @floatFromInt(g.rng.intn(8)));
    g.projs.add(projectile.newFirebolt(p.Pos, dir, dmg, aimYVel(p.Pos.y + projectile.fireboltMuzzleDY, g.mouseGround.y + 0.9, distXZ(p.Pos, g.mouseGround), projectile.fireboltSpeed)));
    g.rumble.play(rumble.cast);
}

// The vertical velocity that carries a shot from its muzzle height to the target
// height over the horizontal flight — how a bolt rains DOWN off a rampart, or an
// arrow climbs up at whoever is camping one. Clamped so degenerate point-blank
// aims can't turn a shot into a mortar.
fn aimYVel(fromY: f32, toY: f32, distH: f32, speed: f32) f32 {
    const ft = maxF(distH, 2.0) / speed;
    return clampF((toY - fromY) / ft, -9.0, 9.0);
}

// Attempt a dodge roll in dir, playing the shared feedback (rumble + popup) on
// success. The keyboard and gamepad paths only differ in how they pick dir, so the
// roll + feedback lives here once.
fn doDodge(g: *Game, dir: rl.Vector3) void {
    if (g.p.startRoll(dir)) {
        g.rumble.play(rumble.dodge);
        // The tuck kicks a fan of scuffed dust out behind the launch point.
        g.parts.burst(&g.rng, v3(g.p.Pos.x - dir.x * 0.3, g.p.Pos.y + 0.12, g.p.Pos.z - dir.z * 0.3), 7, 2.6, 0.07, 0.4, mathx.withAlpha(DUST_COLOR, 110), 5);
    }
}

// Drink a belt potion and toast the result. Shared by the keyboard (1/2) and gamepad
// (L1/R1) bindings so the two input paths can't drift.
fn useHealthPotion(g: *Game) void {
    if (g.p.drinkHealth()) g.setToast("Drank a Health Potion", .{});
}
fn useManaPotion(g: *Game) void {
    if (g.p.drinkMana()) g.setToast("Drank a Mana Potion", .{});
}

// ---- Gamepad ----
// Left stick moves; right stick aims (and targets a nearby foe); X attacks, Y casts
// Firebolt, B dodges, L1/R1 drink potions, Start opens the menu (handled in run()).
const PAD = 0; // first connected controller
const STICK_DEADZONE = 0.25; // ignore small stick drift
const AIM_REACH = 6.0; // how far ahead the right stick projects the aim point

// Read a stick as a unit XZ direction (stick up = -Z = "forward", matching the camera
// and the WASD mapping). Returns zero inside the deadzone; otherwise a unit vector, so
// movement is full-speed and facing stays unit-length like the keyboard path.
fn stickXZ(axisX: rl.GamepadAxis, axisY: rl.GamepadAxis) rl.Vector3 {
    const v = v3(rl.getGamepadAxisMovement(PAD, axisX), 0, rl.getGamepadAxisMovement(PAD, axisY));
    if (lenXZ(v) < STICK_DEADZONE) return mathx.zero3;
    return dirXZ(mathx.zero3, v); // normalize to a unit heading
}

// Pick a foe to engage with the gamepad: the best-scored live monster in vision —
// nearest by default, biased toward `aimDir` when the right stick is pushed. Updates
// hoverMonster so the HUD highlights it; returns the monster id, or null if none.
fn padAcquireTarget(g: *Game, aimDir: rl.Vector3) ?i32 {
    var bestID: ?i32 = null;
    var bestScore: f32 = -std.math.floatMax(f32);
    const aiming = lenXZ(aimDir) > 0;
    for (g.liveMonsters()) |*m| {
        if (!m.alive() or !g.inVision(m.Pos)) continue;
        const to = dirXZ(g.p.Pos, m.Pos);
        // Near foes score higher; when aiming, alignment with the stick dominates.
        var score = -distXZ(g.p.Pos, m.Pos);
        if (aiming) score += (to.x * aimDir.x + to.z * aimDir.z) * 8.0;
        if (score > bestScore) {
            bestScore = score;
            bestID = m.id;
        }
    }
    if (bestID) |id| g.hoverMonster = id;
    return bestID;
}

fn handleGamepad(g: *Game) void {
    if (!rl.isGamepadAvailable(PAD)) return;
    const p = &g.p;

    // Left stick: movement (overrides click-to-move, like the keyboard does).
    const mv = stickXZ(.left_x, .left_y);
    if (lenXZ(mv) > 0) {
        g.kbMove = mv;
        p.hasMoveTarget = false;
        p.targetMonster = -1;
    }

    // Right stick: aim. Project a ground point ahead of the hero so the existing
    // Firebolt / dodge / hover logic can all key off g.mouseGround.
    const aimDir = stickXZ(.right_x, .right_y); // already a unit heading (or zero)
    const aiming = lenXZ(aimDir) > 0;
    if (aiming) {
        g.mouseGround = v3(p.Pos.x + aimDir.x * AIM_REACH, 0, p.Pos.z + aimDir.z * AIM_REACH);
        _ = padAcquireTarget(g, aimDir); // highlight who we'd hit
    }

    // X: attack — engage the best foe (nearest, biased to the aim direction). The
    // auto-attack + chase then drive it, exactly like clicking a monster with the mouse.
    if (rl.isGamepadButtonDown(PAD, .right_face_left) and !p.rolling()) {
        if (padAcquireTarget(g, aimDir)) |id| {
            p.targetMonster = id;
            p.hasMoveTarget = false;
        }
    }

    // Y: cast Firebolt toward the aim point (falls back to facing when not aiming).
    if (rl.isGamepadButtonDown(PAD, .right_face_up) and !p.rolling()) {
        if (!aiming) g.mouseGround = v3(p.Pos.x + p.Facing.x * AIM_REACH, 0, p.Pos.z + p.Facing.z * AIM_REACH);
        castFirebolt(g);
    }

    // B: dodge roll (movement direction, else aim direction, else facing).
    if (rl.isGamepadButtonPressed(PAD, .right_face_right)) {
        var dir = g.kbMove;
        if (lenXZ(dir) < 1e-3) dir = aimDir;
        doDodge(g, dir);
    }

    // L1 / R1: potions.
    if (rl.isGamepadButtonPressed(PAD, .left_trigger_1)) useHealthPotion(g);
    if (rl.isGamepadButtonPressed(PAD, .right_trigger_1)) useManaPotion(g);
}

// The Start button, guarded by controller presence. Used across scenes for
// menu / confirm, mirroring Enter.
fn padStartPressed() bool {
    return rl.isGamepadAvailable(PAD) and rl.isGamepadButtonPressed(PAD, .middle_right);
}

// updateAim refreshes the ground point under the cursor and the hovered monster.
fn updateAim(g: *Game) void {
    const ray = rl.getScreenToWorldRay(rl.getMousePosition(), g.rig.cam);
    // Terrain-aware pick: a click on a rampart top lands ON the rampart (with its
    // height), not on the floor plane hidden beneath it.
    if (g.w.pickGround(ray)) |pt| g.mouseGround = pt;

    g.hoverMonster = -1;
    var best: f32 = std.math.floatMax(f32);
    for (g.liveMonsters()) |*m| {
        if (!m.alive() or !g.inVision(m.Pos)) continue; // can't target what darkness hides
        const d = distXZ(m.Pos, g.mouseGround);
        if (d < m.Radius + 0.6 and d < best) {
            best = d;
            g.hoverMonster = m.id;
        }
    }
}

// ---- Player movement + attack ----

fn updatePlayerMovement(g: *Game, dt: f32) void {
    const p = &g.p;
    // Feet on the ground every frame (covers teleports and standing on a ramp).
    p.Pos.y = g.w.groundY(p.Pos.x, p.Pos.z);

    // A dodge roll overrides all other movement and steering.
    if (p.rolling()) {
        const step = v3(p.rollDir.x * playermod.rollSpeed * dt, 0, p.rollDir.z * playermod.rollSpeed * dt);
        p.Pos = g.w.moveWithCollision(p.Pos, step, p.Radius);
        return;
    }

    var dir = mathx.zero3;
    var moving = false;

    if (lenXZ(g.kbMove) > 0) {
        dir = g.kbMove;
        moving = true;
    } else if (p.targetMonster >= 0) {
        if (g.monsterByID(p.targetMonster)) |m| {
            if (m.alive()) {
                p.Facing = dirXZ(p.Pos, m.Pos);
                // Close to half a body-radius inside reach so the hero settles into
                // solid striking range instead of hovering at the exact edge.
                if (distXZ(p.Pos, m.Pos) > playerReach(p.atkRange, m.Radius) - m.Radius * 0.5) {
                    dir = p.Facing;
                    moving = true;
                }
            } else p.targetMonster = -1;
        } else p.targetMonster = -1;
    } else if (p.hasMoveTarget) {
        if (distXZ(p.Pos, p.moveTarget) > 0.25) {
            dir = dirXZ(p.Pos, p.moveTarget);
            moving = true;
        } else p.hasMoveTarget = false;
    }

    if (moving and lenXZ(dir) > 0) {
        p.Facing = dir;
        const step = v3(dir.x * p.Speed * dt, 0, dir.z * p.Speed * dt);
        p.Pos = g.w.moveWithCollision(p.Pos, step, p.Radius);
        p.walkBob += dt * 12;
        // Each stride kicks a little dust off the road — the ground answers the boot.
        g.stepPuff -= dt;
        if (g.stepPuff <= 0) {
            g.stepPuff = 0.17;
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                g.parts.spawn(.{
                    .Pos = v3(p.Pos.x - dir.x * 0.25 + (g.rng.float() - 0.5) * 0.3, p.Pos.y + 0.06, p.Pos.z - dir.z * 0.25 + (g.rng.float() - 0.5) * 0.3),
                    .Vel = v3(-dir.x * 0.4 + (g.rng.float() - 0.5) * 0.5, 0.35 + g.rng.float() * 0.4, -dir.z * 0.4 + (g.rng.float() - 0.5) * 0.5),
                    .Life = 0.3 + g.rng.float() * 0.2,
                    .maxLife = 0.5,
                    .Size = 0.05 + g.rng.float() * 0.03,
                    .Color = mathx.withAlpha(DUST_COLOR, 80),
                    .grav = 1.2,
                    .drag = 2.2,
                });
            }
        }
    }
}

fn updatePlayerAttack(g: *Game) void {
    const p = &g.p;
    if (p.rolling() or p.targetMonster < 0 or p.atkCD > 0) return;
    const m = g.monsterByID(p.targetMonster) orelse {
        p.targetMonster = -1;
        return;
    };
    if (!m.alive()) {
        p.targetMonster = -1;
        return;
    }
    if (distXZ(p.Pos, m.Pos) <= playerReach(p.atkRange, m.Radius) and @abs(m.Pos.y - p.Pos.y) < SAME_GROUND_DY) {
        var dmg = g.rng.range(p.MinDmg, p.MaxDmg);
        const crit = g.rng.float() < CRIT_CHANCE;
        if (crit) dmg *= CRIT_MULT;
        p.Facing = dirXZ(p.Pos, m.Pos);
        p.swing = playermod.swingDur;
        p.atkCD = p.atkRate;
        g.rumble.play(if (crit) rumble.crit_hit else rumble.attack_hit);
        damageMonster(g, m, dmg, crit);
    }
}

fn damageMonster(g: *Game, m: *Monster, dmg: f32, crit: bool) void {
    m.HP -= dmg;
    m.hitFlash = monster.monster_hitflash;
    m.aggro = true;
    // Hit sparks: a few pale chips off the body; crits flare bigger and golder.
    // (No floating damage numbers by owner decree — the sparks ARE the feedback.)
    const hitAt = v3(m.Pos.x, m.Pos.y + MONSTER_TORSO_BASE + m.Height * 0.5, m.Pos.z);
    if (crit) {
        g.parts.burst(&g.rng, hitAt, 12, 5.5, 0.11, 0.5, rgba(255, 215, 90, 255), 9);
    } else {
        g.parts.burst(&g.rng, hitAt, 5, 4.0, 0.08, 0.35, rgba(255, 235, 200, 230), 9);
    }
    // And the wound itself: heavy dark droplets of the body's own ichor, falling
    // fast — sparks say "impact", these say "flesh".
    const gore = lerpColor(m.Color, rgba(96, 12, 14, 255), 0.65);
    g.parts.burst(&g.rng, hitAt, if (crit) 7 else 4, 3.2, 0.085, 0.5, gore, 15);
    if (m.HP <= 0 and !m.dying) killMonster(g, m);
}

fn killMonster(g: *Game, m: *Monster) void {
    m.HP = 0;
    m.dying = true;
    m.deathTimer = monster.monster_death_fade;
    g.kills += 1;
    g.rumble.play(rumble.kill);
    // Death burst: the body's own color scattering out, with dark gore underneath.
    const at = v3(m.Pos.x, m.Pos.y + MONSTER_TORSO_BASE + m.Height * 0.45, m.Pos.z);
    const n: usize = if (m.boss) 34 else 16;
    g.parts.burst(&g.rng, at, n, 6.0, 0.13, 0.7, lerpColor(m.Color, rl.Color.white, 0.25), 10);
    g.parts.burst(&g.rng, at, n / 2, 3.5, 0.16, 0.9, lerpColor(m.Color, rl.Color.black, 0.45), 12);
    if (g.p.addXP(m.XP)) onLevelUp(g);
    // rollLoot scatters in XZ without terrain knowledge: re-seat each new drop on
    // the ground it actually landed on (a rampart kill may scatter off the edge).
    const firstNew = g.lootList.items.len;
    loot.rollLoot(m, &g.rng, &g.lootList);
    for (g.lootList.items[firstNew..]) |*d| d.Pos = g.w.snapY(d.Pos);
    if (m.boss) g.setToast("{s} has been slain!", .{m.Name});
    if (g.p.targetMonster == m.id) g.p.targetMonster = -1;
}

fn onLevelUp(g: *Game) void {
    g.setBanner(LEVELUP_BANNER_DUR, "Level {d}!", .{g.p.Level});
    g.rumble.play(rumble.level_up);
    g.shake = maxF(g.shake, 0.3);
    // A golden fountain out of the hero: slow, buoyant motes that hang in the air.
    g.parts.burst(&g.rng, v3(g.p.Pos.x, g.p.Pos.y + 1.2, g.p.Pos.z), 30, 4.5, 0.12, 1.3, rgba(255, 225, 110, 255), -2);
    g.parts.burst(&g.rng, v3(g.p.Pos.x, g.p.Pos.y + 0.5, g.p.Pos.z), 14, 2.0, 0.09, 1.6, rgba(255, 250, 210, 255), -3);
}

// ---- Monster AI ----

fn moveMonster(g: *Game, m: *Monster, dir: rl.Vector3, dt: f32) void {
    if (lenXZ(dir) < 1e-4) return;
    m.Pos = g.w.moveWithCollision(m.Pos, v3(dir.x * m.Speed * dt, 0, dir.z * m.Speed * dt), m.Radius);
}

fn updateMonster(g: *Game, m: *Monster, dt: f32) void {
    m.Pos.y = g.w.groundY(m.Pos.x, m.Pos.z); // feet on the ground (spawns, ramps)
    if (m.hitFlash > 0) m.hitFlash -= dt;
    if (m.atkCD > 0) m.atkCD -= dt;
    m.bob += dt * (m.Speed + 2);

    // Committed strike: freeze + telegraph, then land it (the player's window to roll).
    if (m.windup > 0) {
        m.windup -= dt;
        if (g.p.alive()) m.Facing = dirXZ(m.Pos, g.p.Pos);
        if (m.windup <= 0) {
            resolveMonsterAttack(g, m);
            m.atkCD = m.atkRate;
        }
        return;
    }

    const toPlayer = distXZ(m.Pos, g.p.Pos);
    if (!g.p.alive()) {
        m.aggro = false;
    } else if (!m.aggro and toPlayer < m.sightRange) {
        m.aggro = true;
    }

    if (!m.aggro) {
        m.wanderTimer -= dt;
        if (m.wanderTimer <= 0) {
            m.wanderTimer = 1.5 + g.rng.float() * 2.5;
            if (g.rng.float() < 0.55) {
                const ang: f32 = @floatCast(g.rng.float64() * 2 * std.math.pi);
                m.wanderDir = v3(cosf(ang), 0, sinf(ang));
            } else m.wanderDir = mathx.zero3;
        }
        if (lenXZ(m.wanderDir) > 0) {
            m.Facing = m.wanderDir;
            moveMonster(g, m, m.wanderDir, dt * 0.45);
        }
        return;
    }

    m.Facing = dirXZ(m.Pos, g.p.Pos);
    if (m.Ranged) {
        // Kite: hold at range, back off if the player gets close, then shoot.
        if (toPlayer > m.atkRange * 0.85) {
            moveMonster(g, m, m.Facing, dt); // == dirXZ(m.Pos, g.p.Pos), already set above
        } else if (toPlayer < m.atkRange * 0.35) {
            moveMonster(g, m, dirXZ(g.p.Pos, m.Pos), dt * 0.7);
        }
        if (toPlayer <= m.atkRange and m.atkCD <= 0) m.windup = m.windupTime;
        return;
    }

    // Melee: close the gap, then commit to a telegraphed swing — but never wind up
    // at someone standing a cliff above or below; keep pressing toward them (which
    // funnels the pack to the ramp) instead of swinging at a wall of stone.
    if (toPlayer > m.atkRange + playermod.radius or @abs(m.Pos.y - g.p.Pos.y) >= SAME_GROUND_DY) {
        moveMonster(g, m, m.Facing, dt); // == dirXZ(m.Pos, g.p.Pos), already set above
    } else if (m.atkCD <= 0) {
        m.windup = m.windupTime;
    }
}

fn resolveMonsterAttack(g: *Game, m: *Monster) void {
    if (!g.p.alive()) return;
    const dmg = g.rng.range(m.MinDmg, m.MaxDmg);
    if (m.Ranged) {
        // Arrows angle up or down to the player's actual elevation — a rampart is
        // cover from the cliff side, never from an archer with a clean line.
        g.projs.add(projectile.newArrow(m.Pos, dirXZ(m.Pos, g.p.Pos), dmg, aimYVel(m.Pos.y + projectile.arrowMuzzleDY, g.p.Pos.y + 1.0, distXZ(m.Pos, g.p.Pos), projectile.arrowSpeed)));
        return;
    }
    // Use the module radius constant — the SAME source the drawn telegraph ring reads
    // (drawMonstersFX) — so standing just outside the red ring is genuinely safe.
    // Melee cannot land across a cliff: reach requires standing on comparable ground.
    if (distXZ(m.Pos, g.p.Pos) <= meleeReach(m.atkRange, playermod.radius) and @abs(m.Pos.y - g.p.Pos.y) < SAME_GROUND_DY) hitPlayer(g, dmg);
}

// Push overlapping monsters apart so a pack doesn't collapse into one point.
fn separateMonsters(g: *Game) void {
    const ms = g.liveMonsters();
    var i: usize = 0;
    while (i < ms.len) : (i += 1) {
        if (!ms[i].alive()) continue;
        var j: usize = i + 1;
        while (j < ms.len) : (j += 1) {
            if (!ms[j].alive()) continue;
            const minD = ms[i].Radius + ms[j].Radius;
            // Squared pre-check: the vast majority of pairs don't overlap, so skip
            // the @sqrt for them; only compute the real distance when they do.
            if (dist2XZ(ms[i].Pos, ms[j].Pos) >= minD * minD) continue;
            const d = distXZ(ms[i].Pos, ms[j].Pos);
            if (d > 1e-3) {
                const push = (minD - d) * 0.5;
                const dir = dirXZ(ms[j].Pos, ms[i].Pos);
                ms[i].Pos = g.w.moveWithCollision(ms[i].Pos, v3(dir.x * push, 0, dir.z * push), ms[i].Radius);
                ms[j].Pos = g.w.moveWithCollision(ms[j].Pos, v3(-dir.x * push, 0, -dir.z * push), ms[j].Radius);
            }
        }
    }
}

fn hitPlayer(g: *Game, dmg: f32) void {
    // I-frames from a dodge roll negate the blow entirely.
    if (g.p.invulnerable()) {
        return;
    }
    g.p.takeDamage(dmg);
    g.damageFlash = DAMAGE_FLASH_DUR;
    g.shake = maxF(g.shake, 0.25);
    g.rumble.play(rumble.hurt);
    g.parts.burst(&g.rng, v3(g.p.Pos.x, g.p.Pos.y + 1.35, g.p.Pos.z), 8, 4.5, 0.1, 0.45, rgba(220, 40, 40, 255), 9);
    if (!g.p.alive()) {
        g.rumble.play(rumble.death); // stronger than `hurt`, so it takes over the fade
        g.scene = .dead;
    }
}

// Retain-in-place: advance every item, keep those for which `keepFn` returns true,
// compacting survivors to the front. `keepFn` mutates the item it's handed (it aliases
// the live slot) and may run side effects (damage, pickups). Returns the new length.
// The per-frame entity sweeps share this instead of each re-rolling a write-index loop.
fn retain(comptime T: type, items: []T, ctx: anytype, comptime keepFn: fn (@TypeOf(ctx), *T) bool) usize {
    var w: usize = 0;
    for (items, 0..) |*it, i| {
        if (keepFn(ctx, it)) {
            if (w != i) items[w] = items[i];
            w += 1;
        }
    }
    return w;
}

// Shared context for the per-frame sweeps: the game plus this frame's dt.
const SweepCtx = struct { g: *Game, dt: f32 };

// Advance one projectile: move, expire on lifetime/obstacle, damage what it strikes.
// Returns false (drop it) when it expires or lands a hit.
fn keepProjectile(c: SweepCtx, pr: *Projectile) bool {
    const g = c.g;
    pr.Pos.x += pr.Vel.x * c.dt;
    pr.Pos.y += pr.Vel.y * c.dt;
    pr.Pos.z += pr.Vel.z * c.dt;
    pr.Life -= c.dt;
    // The firebolt sheds a spark trail as it flies (arrows fly clean).
    if (pr.FromPlayer) {
        g.parts.spawn(.{
            .Pos = v3(pr.Pos.x + (g.rng.float() - 0.5) * 0.25, pr.Pos.y + (g.rng.float() - 0.5) * 0.25, pr.Pos.z + (g.rng.float() - 0.5) * 0.25),
            .Vel = v3(-pr.Vel.x * 0.06, 0.6 + g.rng.float(), -pr.Vel.z * 0.06),
            .Life = 0.28 + g.rng.float() * 0.22,
            .maxLife = 0.5,
            .Size = 0.09,
            .Color = if (g.rng.float() < 0.6) projectile.fireboltColor else rgba(255, 220, 120, 255),
            .grav = -1.5,
            .drag = 1.5,
        });
    }
    if (pr.Life <= 0 or g.w.rayHitsObstacle(pr.Pos, pr.Radius)) {
        impactBurst(g, pr);
        return false;
    }
    // Hits require the shot to actually pass through the body's height band — a
    // bolt raining down from a rampart sails clean over the heads between it and
    // its mark instead of clipping everything on the way.
    if (pr.FromPlayer) {
        for (g.liveMonsters()) |*m| {
            if (m.alive() and dist2XZ(m.Pos, pr.Pos) < (m.Radius + pr.Radius) * (m.Radius + pr.Radius) and @abs(pr.Pos.y - (m.Pos.y + m.Height * 0.55)) < m.Height * 0.55 + 0.7) {
                damageMonster(g, m, pr.Damage, false);
                impactBurst(g, pr);
                return false;
            }
        }
    } else if (g.p.alive() and dist2XZ(g.p.Pos, pr.Pos) < (g.p.Radius + pr.Radius) * (g.p.Radius + pr.Radius) and @abs(pr.Pos.y - (g.p.Pos.y + 1.1)) < 1.7) {
        hitPlayer(g, pr.Damage);
        impactBurst(g, pr);
        return false;
    }
    return true;
}

// A projectile ends its flight: the firebolt detonates into a two-tone flash; an
// arrow just splinters faintly.
fn impactBurst(g: *Game, pr: *const Projectile) void {
    if (pr.FromPlayer) {
        g.parts.burst(&g.rng, pr.Pos, 16, 6.5, 0.13, 0.45, rgba(255, 170, 60, 255), 8);
        g.parts.burst(&g.rng, pr.Pos, 8, 3.0, 0.1, 0.6, rgba(255, 235, 160, 255), 4);
    } else {
        g.parts.burst(&g.rng, pr.Pos, 5, 3.0, 0.07, 0.3, rgba(210, 205, 180, 200), 10);
    }
}
fn updateProjectiles(g: *Game, dt: f32) void {
    g.projs.count = retain(Projectile, g.projs.items(), SweepCtx{ .g = g, .dt = dt }, keepProjectile);
}

// Loot: bob in place; collected (and dropped) when the player walks over it.
fn keepLoot(c: SweepCtx, d: *LootDrop) bool {
    d.bob += c.dt * 3;
    // Same-level pickup only: standing on the rampart edge must not hoover the
    // drops glittering on the floor below.
    if (distXZ(d.Pos, c.g.p.Pos) < c.g.p.Radius + 1.3 and @abs(d.Pos.y - c.g.p.Pos.y) < 1.2) {
        // Only remove the drop if it was actually picked up; a full belt leaves the
        // potion glittering on the ground instead of destroying it with a lying toast.
        if (collect(c.g, d.*)) return false;
    }
    return true;
}
fn updateLoot(g: *Game, dt: f32) void {
    const n = retain(LootDrop, g.lootList.items, SweepCtx{ .g = g, .dt = dt }, keepLoot);
    g.lootList.shrinkRetainingCapacity(n);
}

// Returns true if the drop was consumed (remove it), false if the pickup was
// declined (e.g. belt already full) so the caller leaves it on the ground.
fn collect(g: *Game, d: LootDrop) bool {
    switch (d.Kind) {
        .gold => {
            g.p.Gold += d.Amount;
            g.parts.burst(&g.rng, v3(d.Pos.x, d.Pos.y + 0.4, d.Pos.z), 8, 2.5, 0.07, 0.6, theme.goldColor, -1);
            return true;
        },
        .health_potion => {
            if (g.p.HealthPots >= playermod.maxPots) return false;
            g.p.HealthPots += 1;
            g.setToast("Picked up a Health Potion", .{});
            return true;
        },
        .mana_potion => {
            if (g.p.ManaPots >= playermod.maxPots) return false;
            g.p.ManaPots += 1;
            g.setToast("Picked up a Mana Potion", .{});
            return true;
        },
    }
}


// Drop faded-out corpses, keeping live monsters packed contiguously at the front.
fn keepMonster(c: SweepCtx, m: *Monster) bool {
    if (m.dying) {
        m.deathTimer -= c.dt;
        if (m.deathTimer <= 0) return false;
    }
    return true;
}
fn updateDeaths(g: *Game, dt: f32) void {
    g.monsterCount = retain(Monster, g.liveMonsters(), SweepCtx{ .g = g, .dt = dt }, keepMonster);
}

// Ambient, non-combat particles: violet motes spiraling up the open portal, a faint
// gold glint over gold piles, warm dust hanging in the torchlight, and dark embers
// smoldering off the area champion.
fn updateAmbientFX(g: *Game, dt: f32) void {
    g.portalPuff -= dt;
    if (g.portalPuff <= 0) {
        g.portalPuff = 0.05;
        // Dust in the torchlight: dim, slow, near-still motes drifting through the
        // lit disc make the AIR visible. Kept faint so they read as atmosphere.
        if (g.rng.float() < 0.55) {
            const dang = g.rng.float() * std.math.tau;
            const dr = (0.25 + 0.75 * g.rng.float()) * TORCH_RADIUS * 0.85;
            g.parts.spawn(.{
                .Pos = v3(g.p.Pos.x + cosf(dang) * dr, g.p.Pos.y + 0.3 + g.rng.float() * 2.4, g.p.Pos.z + sinf(dang) * dr),
                .Vel = v3((g.rng.float() - 0.5) * 0.5, 0.08 + g.rng.float() * 0.18, (g.rng.float() - 0.5) * 0.5),
                .Life = 2.4 + g.rng.float() * 1.2,
                .maxLife = 3.6,
                .Size = 0.022 + g.rng.float() * 0.022,
                .Color = rgba(255, 216, 160, 48),
                .grav = 0,
                .drag = 0.25,
            });
        }
        // The hero's torch spits: now and then a live ember leaps off the flame and
        // sails a short arc before dying — fire is never perfectly still.
        if (g.rng.float() < 0.22 and g.p.alive()) {
            g.parts.spawn(.{
                .Pos = torchFlameWorld(&g.p),
                .Vel = v3((g.rng.float() - 0.5) * 0.7, 1.0 + g.rng.float() * 0.9, (g.rng.float() - 0.5) * 0.7),
                .Life = 0.45 + g.rng.float() * 0.35,
                .maxLife = 0.8,
                .Size = 0.04 + g.rng.float() * 0.025,
                .Color = if (g.rng.float() < 0.6) rgba(255, 180, 70, 240) else rgba(255, 120, 40, 220),
                .grav = -0.7, // buoyant: hot air carries it up before it gutters
                .drag = 1.4,
            });
        }
        // The champion smolders: dark-red embers curl off its shoulders whenever it
        // stands in your light — you feel which one is the boss before the name.
        for (g.liveMonsters()) |*m| {
            if (!m.boss or !m.alive()) continue;
            if (distXZ(m.Pos, g.p.Pos) > TORCH_RADIUS or g.rng.float() > 0.55) continue;
            g.parts.spawn(.{
                .Pos = v3(m.Pos.x + (g.rng.float() - 0.5) * m.Radius * 1.7, m.Pos.y + MONSTER_TORSO_BASE + m.Height * (0.5 + g.rng.float() * 0.35), m.Pos.z + (g.rng.float() - 0.5) * m.Radius * 1.7),
                .Vel = v3((g.rng.float() - 0.5) * 0.4, 0.9 + g.rng.float() * 0.8, (g.rng.float() - 0.5) * 0.4),
                .Life = 0.7 + g.rng.float() * 0.4,
                .maxLife = 1.1,
                .Size = 0.06 + g.rng.float() * 0.04,
                .Color = if (g.rng.float() < 0.7) rgba(255, 70, 25, 210) else rgba(255, 140, 40, 230),
                .grav = -1.1,
                .drag = 1.0,
            });
        }
        if (g.w.PortalOpen) {
            const ang = g.rng.float() * std.math.tau;
            const r = 1.0 + g.rng.float() * 0.9;
            const pp = g.w.PortalPos;
            g.parts.spawn(.{
                .Pos = v3(pp.x + cosf(ang) * r, 0.1 + g.rng.float() * 0.6, pp.z + sinf(ang) * r),
                .Vel = v3(-sinf(ang) * 1.2, 1.6 + g.rng.float() * 1.4, cosf(ang) * 1.2), // tangent = swirl
                .Life = 1.4,
                .maxLife = 1.4,
                .Size = 0.09,
                .Color = if (g.rng.float() < 0.5) rgba(150, 110, 255, 220) else rgba(90, 140, 255, 210),
                .grav = -0.8, // buoyant: accelerates upward as it rises
                .drag = 0.4,
            });
        }
        // One glint at a time, over a random visible gold pile: cheap treasure sparkle.
        if (g.lootList.items.len > 0) {
            const d = &g.lootList.items[@intCast(g.rng.intn(@intCast(g.lootList.items.len)))];
            if (d.Kind == .gold and distXZ(d.Pos, g.p.Pos) <= TORCH_RADIUS and g.rng.float() < 0.35) {
                g.parts.spawn(.{
                    .Pos = v3(d.Pos.x + (g.rng.float() - 0.5) * 0.4, d.Pos.y + 0.35 + g.rng.float() * 0.3, d.Pos.z + (g.rng.float() - 0.5) * 0.4),
                    .Vel = v3(0, 0.8, 0),
                    .Life = 0.5,
                    .maxLife = 0.5,
                    .Size = 0.05,
                    .Color = theme.goldColor,
                    .grav = -0.5,
                    .drag = 0,
                });
            }
        }
    }
}

fn updatePortal(g: *Game) void {
    if (!g.w.PortalOpen and g.remainingMonsters() == 0) {
        g.w.PortalOpen = true;
        g.setToast("Area cleared - a portal has opened!", .{});
    }
    if (g.w.PortalOpen and distXZ(g.p.Pos, g.w.PortalPos) < 2.4) {
        if (g.playtest) {
            endPlaytest(g);
            g.ed.status("portal reached - playtest complete", .{});
        } else if (g.w.IsLast) {
            g.scene = .victory;
        } else {
            g.enterArea(g.areaIndex + 1);
        }
    }
}

// Launch a playtest of the CURRENT in-memory map from the editor: real spawns,
// real fog of war, real HUD. Every exit (Esc, death, portal) leads back to the
// editor with the author's map untouched — no disk round-trip.
pub fn startPlaytest(g: *Game) void {
    g.playtest = true;
    g.paused = false;
    g.p = playermod.newPlayer(g.map.spawn);
    g.monsterCount = 0;
    g.projs.count = 0;
    g.lootList.clearRetainingCapacity();
    g.parts.clear();
    g.w.PortalOpen = false;
    g.fog.reset(g.w.HalfW, g.w.HalfD);
    g.fog.sync();
    g.spawnPacks();
    g.rig.snap(g.p.Pos);
    g.torchXZ = torchFlameWorld(&g.p);
    g.setBanner(AREA_BANNER_DUR, "Playtest: {s}", .{g.map.name.slice()});
    g.scene = .playing;
}

// Ctrl+F5 (crawler): playtest starting from the editor's cursor, not the spawn.
pub fn startPlaytestAt(g: *Game, at: rl.Vector3) void {
    startPlaytest(g);
    g.p.Pos = g.w.snapY(at);
    g.rig.snap(g.p.Pos);
    g.torchXZ = torchFlameWorld(&g.p);
}

fn endPlaytest(g: *Game) void {
    g.playtest = false;
    editor.apply(g); // clean world, no monsters, fog fully revealed
    g.scene = .editor;
}

// ---- Rendering (frozen torchlight + baked scene mesh) ----

// The hero: a cloaked, hooded ranger. Plain tint — torchlight shades + shadows it.
// Drawn HERO_SCALE bigger about the feet (depth pass included, so the shadow grows
// with the body).
fn drawHeroBody(p: *const Player) void {
    const base = p.Pos;
    beginHeroScale(base);
    defer rl.gl.rlPopMatrix();
    const bob = 0.05 * sinf(p.walkBob);
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);

    var cloak = rgba(54, 74, 60, 255);
    const hood = rgba(44, 60, 50, 255);
    const skin = rgba(208, 176, 140, 255);

    // Dodge roll: a low tuck, brightened while invulnerable.
    if (p.rolling()) {
        const tt = p.rollTimer / playermod.rollDur;
        const low = 0.35 + 0.25 * sinf((1 - tt) * std.math.pi);
        var col = cloak;
        if (p.invulnerable()) col = lerpColor(cloak, rl.Color.white, 0.45);
        rl.drawCapsule(v3(base.x - f.x * 0.2, low, base.z - f.z * 0.2), v3(base.x + f.x * 0.2, low, base.z + f.z * 0.2), 0.42, 12, 8, col);
        return;
    }

    const legCol = rgba(40, 40, 46, 255);
    for ([_]f32{ -1, 1 }) |s| {
        const lx = base.x + right.x * 0.18 * s;
        const lz = base.z + right.z * 0.18 * s;
        rl.drawCapsule(v3(lx, 0.08, lz), v3(lx, 0.55 + bob, lz), 0.16, 8, 6, legCol);
    }

    if (p.hitFlash > 0) cloak = lerpColor(cloak, rl.Color.white, 0.6);
    // The cloak flares from the belt into an A-line skirt over the legs — the shape
    // that says "cloaked wanderer" from the iso camera (feet still peek below the hem).
    rl.drawCylinderEx(v3(base.x, 0.6 + bob, base.z), v3(base.x, 0.16 + bob * 0.5, base.z), 0.33, 0.54, 10, lerpColor(cloak, rl.Color.black, 0.22));
    rl.drawCapsule(v3(base.x, 0.5 + bob, base.z), v3(base.x, 1.42 + bob, base.z), 0.42, 12, 8, cloak);
    rl.drawCapsule(v3(base.x - f.x * 0.22, 0.55 + bob, base.z - f.z * 0.22), v3(base.x - f.x * 0.12, 1.25 + bob, base.z - f.z * 0.12), 0.3, 10, 6, lerpColor(cloak, rl.Color.black, 0.25));
    // A leather belt cinching the cloak, with a brass buckle at the front — one warm
    // metal accent that breaks the silhouette into torso-over-skirt.
    rl.drawCylinderEx(v3(base.x, 0.88 + bob, base.z), v3(base.x, 0.98 + bob, base.z), 0.435, 0.42, 10, rgba(74, 50, 30, 255));
    sphere(v3(base.x + f.x * 0.42, 0.93 + bob, base.z + f.z * 0.42), 0.06, theme.trimColor);

    // Sleeved arms out to the tools of the trade: bow hand forward-right, torch
    // hand out left — without them the props float beside the body.
    const sleeve = lerpColor(hood, rl.Color.black, 0.1);
    const bhandB = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15 + bob, base.z - f.z * 0.18 + right.z * 0.4);
    rl.drawCapsule(v3(base.x + right.x * 0.28 + f.x * 0.05, 1.3 + bob, base.z + right.z * 0.28 + f.z * 0.05), bhandB, 0.1, 6, 4, sleeve);
    const thandB = v3(base.x - right.x * TORCH_GRIP_RIGHT + f.x * TORCH_GRIP_FWD, 1.28, base.z - right.z * TORCH_GRIP_RIGHT + f.z * TORCH_GRIP_FWD);
    rl.drawCapsule(v3(base.x - right.x * 0.28 + f.x * 0.02, 1.3 + bob, base.z - right.z * 0.28 + f.z * 0.02), thandB, 0.1, 6, 4, sleeve);

    sphere(v3(base.x, 1.72 + bob, base.z), 0.34, hood);
    sphere(v3(base.x + f.x * 0.22, 1.70 + bob, base.z + f.z * 0.22), 0.2, lerpColor(skin, rl.Color.black, 0.35));
    rl.drawCylinderEx(v3(base.x - f.x * 0.1, 1.9 + bob, base.z - f.z * 0.1), v3(base.x - f.x * 0.3, 2.18 + bob, base.z - f.z * 0.3), 0.18, 0.02, 6, hood);
    // Brass clasp at the throat where the hood gathers.
    sphere(v3(base.x + f.x * 0.3, 1.46 + bob, base.z + f.z * 0.3), 0.055, theme.trimColor);

    // Quiver slung across the back, fletching poking out over the shoulder.
    const qb = v3(base.x - f.x * 0.4 - right.x * 0.15, 0.9 + bob, base.z - f.z * 0.4 - right.z * 0.15);
    const qt = v3(qb.x - right.x * 0.12, qb.y + 0.62, qb.z - right.z * 0.12);
    rl.drawCylinderEx(qb, qt, 0.12, 0.11, 6, rgba(84, 56, 34, 255));
    rl.drawCylinderEx(qt, v3(qt.x - right.x * 0.03, qt.y + 0.16, qt.z - right.z * 0.03), 0.08, 0.05, 5, rgba(190, 185, 165, 255));

    const bowCol = rgba(96, 66, 38, 255);
    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15 + bob, base.z - f.z * 0.18 + right.z * 0.4);
    rl.drawCylinderEx(bhand, v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18), 0.07, 0.03, 5, bowCol);
    rl.drawCylinderEx(bhand, v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18), 0.07, 0.03, 5, bowCol);

    const thand = v3(base.x - right.x * TORCH_GRIP_RIGHT + f.x * TORCH_GRIP_FWD, 0.95, base.z - right.z * TORCH_GRIP_RIGHT + f.z * TORCH_GRIP_FWD);
    rl.drawCylinderEx(thand, v3(thand.x, thand.y + 0.55, thand.z), 0.05, 0.04, 5, rgba(70, 48, 30, 255));
}

// Emissive hero bits (no shadow): bowstring, melee swing arc, the torch flame + embers.
// Under the same feet-anchored scale as the body, so the flame stays in the hand.
fn drawHeroFX(p: *const Player, t: f32) void {
    const base = p.Pos;
    beginHeroScale(base);
    defer rl.gl.rlPopMatrix();
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);

    if (p.rolling()) {
        const tt = p.rollTimer / playermod.rollDur;
        rl.drawCircle3D(v3(base.x, 0.05, base.z), p.Radius + 0.4 * (1 - tt), v3(1, 0, 0), 90, rgba(200, 210, 230, mathx.u8f(120 * tt)));
        return;
    }

    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15, base.z - f.z * 0.18 + right.z * 0.4);
    rl.drawLine3D(v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18), v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18), rgba(200, 200, 190, 200));

    // Melee swing arc.
    if (p.swing > 0) {
        const sw = p.swing / playermod.swingDur;
        const reach = 0.7 + sw * 0.9;
        const shoulder = v3(base.x + f.x * 0.3, 1.2, base.z + f.z * 0.3);
        const tip = v3(base.x + f.x * reach, 1.2 + sw * 0.4, base.z + f.z * reach);
        rl.drawCylinderEx(shoulder, tip, 0.07, 0.03, 6, rgba(255, 240, 190, 255));
    }

    // Torch bounce on the carrier: with the light at his own hand the hero's camera
    // side falls into self-shadow, so a faint warm emissive wash keeps him readable
    // — the fire lighting the one who holds it.
    sphere(v3(base.x, 1.05, base.z), 0.78, rgba(255, 170, 90, 26));
    sphere(v3(base.x, 1.6, base.z), 0.45, rgba(255, 185, 110, 30));

    // The torch burns in the firebolt's family language: wide corona, orange body,
    // a live flame TONGUE licking upward (stretching and swaying on two beats), and
    // a white-hot heart — plus the ember drift above.
    const flick = 1 + 0.18 * sinf(t * 22) + 0.1 * sinf(t * 37);
    const thand = v3(base.x - right.x * TORCH_GRIP_RIGHT + f.x * TORCH_GRIP_FWD, 0.95, base.z - right.z * TORCH_GRIP_RIGHT + f.z * TORCH_GRIP_FWD);
    const flame = v3(thand.x, TORCH_FLAME_Y, thand.z);
    sphere(flame, 0.5 * flick, rgba(230, 80, 20, 40)); // wide soft halo
    sphere(flame, 0.32 * flick, rgba(235, 95, 25, 120));
    const tongueH = 0.44 + 0.11 * sinf(t * 13) + 0.06 * sinf(t * 29);
    const sway = 0.055 * sinf(t * 9) + 0.03 * sinf(t * 17);
    rl.drawCylinderEx(v3(flame.x, flame.y - 0.1, flame.z), v3(flame.x + sway, flame.y + tongueH, flame.z + sway * 0.6), 0.15, 0.0, 6, rgba(255, 150, 40, 215));
    rl.drawCylinderEx(v3(flame.x, flame.y - 0.06, flame.z), v3(flame.x + sway * 0.7, flame.y + tongueH * 0.6, flame.z + sway * 0.42), 0.08, 0.0, 6, rgba(255, 240, 175, 255));
    sphere(v3(flame.x, flame.y + 0.02, flame.z), 0.115 * flick, rgba(255, 246, 205, 255));
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const ph = @mod(t * 0.8 + iff * 0.23, 1.0);
        const drift = 0.14 * sinf(t * 3 + iff * 1.9);
        const ep = v3(flame.x + drift, flame.y + 0.15 + ph * 0.95, flame.z + drift * 0.5);
        sphere(ep, 0.045 * (1 - ph), rgba(255, 160, 60, mathx.u8f((1 - ph) * 170)));
    }

    rl.drawCircle3D(v3(base.x, 0.045, base.z), p.Radius + 0.15, v3(1, 0, 0), 90, rgba(150, 190, 255, 90));
}

pub fn drawWalls(w: *const world.World) void {
    const hw = w.HalfW;
    const hd = w.HalfD;
    const wallH = 4.0;
    const t = 1.2;
    const col = w.Accent;
    // North/south walls run the WIDTH; east/west run the DEPTH (rect arenas).
    const segs = [_]rl.Vector3{
        v3(0, wallH / 2, -hd), v3(0, wallH / 2, hd),
        v3(-hw, wallH / 2, 0), v3(hw, wallH / 2, 0),
    };
    const sizes = [_]rl.Vector3{
        v3(hw * 2 + t, wallH, t), v3(hw * 2 + t, wallH, t),
        v3(t, wallH, hd * 2 + t), v3(t, wallH, hd * 2 + t),
    };
    // Each rampart gets a stone profile instead of one extruded slab: a paler
    // capstone course overhanging the top, and a darker plinth at the foot.
    const cap = lerpColor(col, rgba(170, 168, 160, 255), 0.3);
    const plinth = lerpColor(col, rl.Color.black, 0.35);
    for (segs, sizes) |seg, size| {
        rl.drawCubeV(seg, size, col);
        rl.drawCubeV(v3(seg.x, wallH + 0.14, seg.z), v3(size.x + 0.35, 0.28, size.z + 0.35), cap);
        rl.drawCubeV(v3(seg.x, 0.3, seg.z), v3(size.x + 0.22, 0.6, size.z + 0.22), plinth);
    }
    // Buttress piers every few strides give the long ramparts a masonry rhythm —
    // walking the arena edge you pass tower after tower instead of one endless slab.
    const pier = lerpColor(col, rl.Color.black, 0.18);
    const pierCap = lerpColor(cap, rl.Color.white, 0.06);
    var px: f32 = -hw;
    while (px <= hw + 0.1) : (px += 9.0) {
        for ([_]f32{ -hd, hd }) |edge| {
            rl.drawCubeV(v3(px, (wallH + 0.5) / 2.0, edge), v3(1.7, wallH + 0.5, t + 0.7), pier);
            rl.drawCubeV(v3(px, wallH + 0.66, edge), v3(2.0, 0.32, t + 1.0), pierCap);
        }
    }
    var pz: f32 = -hd;
    while (pz <= hd + 0.1) : (pz += 9.0) {
        for ([_]f32{ -hw, hw }) |edge| {
            rl.drawCubeV(v3(edge, (wallH + 0.5) / 2.0, pz), v3(t + 0.7, wallH + 0.5, 1.7), pier);
            rl.drawCubeV(v3(edge, wallH + 0.66, pz), v3(t + 1.0, 0.32, 2.0), pierCap);
        }
    }
}

const MONSTER_BOB_AMP = 0.05;
const MONSTER_TORSO_BASE = 0.4;
const MONSTER_HEAD_GAP = 0.25;

fn monsterBob(m: *const Monster) f32 {
    return MONSTER_BOB_AMP * sinf(m.bob);
}

// Where a pib's knife hand sits this frame, and how far the blade is raised into its
// overhead strike pose. Shared by the body draw (grip + blade) and the emissive FX
// pass (the blade glint), so the sparkle always rides the actual blade tip.
const PibGrip = struct { hand: rl.Vector3, raise: f32, f: rl.Vector3 };
fn pibGrip(m: *const Monster) PibGrip {
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    const raise: f32 = m.windupProgress() * 0.7;
    return .{
        .hand = v3(m.Pos.x + right.x * m.Radius * 0.95 + f.x * 0.15, MONSTER_TORSO_BASE + 0.42 + monsterBob(m) + raise, m.Pos.z + right.z * m.Radius * 0.95 + f.z * 0.15),
        .raise = raise,
        .f = f,
    };
}
// The knife's point, given the grip: carried near-vertical over the shoulder (so the
// blade is a proud mast at gameplay zoom), leaning forward and reaching higher as the
// overhead strike builds.
fn pibKnifeTip(grip: PibGrip) rl.Vector3 {
    const fwd = 0.05 + grip.raise * 0.45;
    return v3(grip.hand.x + grip.f.x * fwd, grip.hand.y + 0.66 + grip.raise * 0.3, grip.hand.z + grip.f.z * fwd);
}
fn monsterHeadY(m: *const Monster, shrink: f32) f32 {
    return MONSTER_TORSO_BASE + (m.Height - 0.5) * shrink + MONSTER_HEAD_GAP * shrink + monsterBob(m);
}

// How far each kind's head juts FORWARD of the spine: posture is silhouette. The
// zombie lolls ahead of its hunch, the brute is neckless-forward, the pib leads with
// its snout; the archer stands straight. Shared with the FX pass so the glowing eyes
// always sit on the face that was actually drawn.
fn monsterHeadFwd(m: *const Monster) f32 {
    return switch (m.Kind) {
        .zombie => m.Radius * 0.6,
        .brute => m.Radius * 0.3,
        .fallen => m.Radius * 0.18,
        .skeleton => 0,
    };
}

// Body + per-kind silhouette. Every appendage is drawn here (not in the FX pass) so
// it exists in BOTH the shadow depth pass and the lit pass: horns and arms cast.
// The whole (ground-relative) body is lifted by the monster's terrain height.
// (pub: the editor draws statuesque encounter previews with the same bodies.)
pub fn drawMonsterBody(m: *const Monster) void {
    rl.gl.rlPushMatrix();
    defer rl.gl.rlPopMatrix();
    rl.gl.rlTranslatef(0, m.Pos.y, 0);
    const bob = monsterBob(m);
    var col = m.Color;
    var shrink: f32 = 1;
    if (m.dying) {
        shrink = clampF(m.deathTimer / monster.monster_death_fade, 0.12, 1);
    } else if (m.hitFlash > 0) {
        col = lerpColor(col, rl.Color.white, 0.75);
    } else if (m.windup > 0) {
        col = lerpColor(col, rgba(255, 80, 40, 255), 0.35 + 0.45 * m.windupProgress());
    }
    const htop = (m.Height - 0.5) * shrink;
    const x = m.Pos.x;
    const z = m.Pos.z;
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    const dark = lerpColor(col, rl.Color.black, 0.3);
    if (m.dying) {
        // The felled body drains into a dark pool that spreads as the corpse fades —
        // the floor remembers the kill for a beat after the silhouette is gone.
        const spread = m.Radius * (0.55 + 1.25 * (1 - shrink));
        rl.drawCylinderEx(v3(x, 0.012, z), v3(x, 0.03, z), spread, spread, 16, rgba(74, 12, 14, 255));
    }
    rl.drawCapsule(v3(x, MONSTER_TORSO_BASE + bob, z), v3(x, MONSTER_TORSO_BASE + htop + bob, z), m.Radius, 8, 4, col);
    const headY = monsterHeadY(m, shrink);
    const headR = m.Radius * 0.7 * shrink;
    // Posture: the head sits forward of the spine by a per-kind amount (hunch, jut,
    // snout-lead); every face feature below hangs off this shared head center.
    const fwd = monsterHeadFwd(m) * shrink;
    const hcx = x + f.x * fwd;
    const hcz = z + f.z * fwd;
    sphere(v3(hcx, headY, hcz), headR, col);

    switch (m.Kind) {
        // Pib: a cute little knife pig. Round ears, a pink snout, a stubby curl of
        // tail, a happy waddle — and a genuinely dangerous knife, raised high for
        // the whole windup so the cuteness stays a threat you must respect.
        .fallen => {
            const waddle = sinf(m.bob * 1.6) * 0.05; // side-to-side toddle
            const hx = hcx + right.x * waddle;
            const hz = hcz + right.z * waddle;
            // Perky triangle pig ears pointing UP — they read from the top-down
            // camera where side-mounted ears would vanish into the head.
            for ([_]f32{ -1, 1 }) |s| {
                const eb = v3(hx + right.x * headR * 0.55 * s, headY + headR * 0.5, hz + right.z * headR * 0.55 * s);
                rl.drawCylinderEx(eb, v3(eb.x + right.x * 0.08 * s - waddle * right.x, eb.y + 0.26 * shrink, eb.z + right.z * 0.08 * s - waddle * right.z), 0.1 * shrink, 0.0, 5, lerpColor(col, rgba(255, 150, 150, 255), 0.35));
            }
            // Snout: a proud pink button, stuck well out front.
            sphere(v3(hx + f.x * headR * 1.0, headY - headR * 0.05, hz + f.z * headR * 1.0), headR * 0.4 * shrink, rgba(238, 148, 148, 255));
            // Curly tail nub, offset opposite the waddle so it wags as it walks.
            const tail = v3(x - f.x * m.Radius * 1.05 - right.x * waddle * 2, MONSTER_TORSO_BASE + 0.25 + bob, z - f.z * m.Radius * 1.05 - right.z * waddle * 2);
            sphere(tail, 0.09 * shrink, lerpColor(col, rgba(255, 150, 150, 255), 0.35));
            // The knife: a comically OVERSIZED blade in its trotter — shouldered like
            // a little pikeman on the march, thrust overhead as the strike telegraph
            // builds. It has to read at gameplay zoom: a big knife on a small pig is
            // funnier AND scarier, and the blade is the pib's whole threat language.
            const grip = pibGrip(m);
            const hand = grip.hand;
            const tip = pibKnifeTip(grip);
            // A stubby trotter arm up to the grip, so the knife is HELD, not floating.
            rl.drawCapsule(v3(x + right.x * m.Radius * 0.6, MONSTER_TORSO_BASE + 0.28 + bob, z + right.z * m.Radius * 0.6), v3(hand.x, hand.y - 0.08, hand.z), 0.09 * shrink, 6, 4, lerpColor(col, rl.Color.black, 0.15));
            // Leather grip with a brass pommel bead.
            rl.drawCylinderEx(v3(hand.x, hand.y - 0.15, hand.z), v3(hand.x, hand.y + 0.05, hand.z), 0.06 * shrink, 0.055 * shrink, 5, rgba(70, 50, 34, 255));
            sphere(v3(hand.x, hand.y - 0.17, hand.z), 0.06 * shrink, theme.trimColor);
            // Crossguard: a proper brass bar across the blade root.
            rl.drawCylinderEx(v3(hand.x - right.x * 0.17, hand.y + 0.06, hand.z - right.z * 0.17), v3(hand.x + right.x * 0.17, hand.y + 0.06, hand.z + right.z * 0.17), 0.04 * shrink, 0.04 * shrink, 4, theme.trimColor);
            // The blade itself: bright cold steel tapering to the point, with a pale
            // edge-bevel line up the spine so it catches light like ground metal.
            // (The death fade shortens it toward the hand with everything else.)
            const tipDrawn = v3(hand.x + (tip.x - hand.x) * shrink, hand.y + (tip.y - hand.y) * shrink, hand.z + (tip.z - hand.z) * shrink);
            rl.drawCylinderEx(v3(hand.x, hand.y + 0.07, hand.z), tipDrawn, 0.095 * shrink, 0.0, 5, rgba(206, 214, 228, 255));
            rl.drawCylinderEx(v3(hand.x + f.x * 0.03, hand.y + 0.1, hand.z + f.z * 0.03), tipDrawn, 0.032 * shrink, 0.0, 4, rgba(240, 246, 252, 255));
        },
        // Zombie: hunched over reaching arms — one out farther than the other,
        // because symmetry reads "healthy" and this thing is not.
        .zombie => {
            const shY = MONSTER_TORSO_BASE + htop * 0.8 + bob;
            const flesh = lerpColor(col, rgba(205, 215, 165, 255), 0.3); // paler rot
            // The hump: a swollen back rising over the shoulders, shoving the head
            // forward and down — the corpse never learned to stand back up straight.
            sphere(v3(x - f.x * m.Radius * 0.4, MONSTER_TORSO_BASE + htop * 0.98 + bob, z - f.z * m.Radius * 0.4), m.Radius * 0.8 * shrink, lerpColor(col, rl.Color.black, 0.15));
            for ([_]f32{ -1, 1 }) |s| {
                const reach: f32 = if (s > 0) 0.9 else 0.68;
                const sh = v3(x + right.x * m.Radius * 0.7 * s, shY, z + right.z * m.Radius * 0.7 * s);
                const hand = v3(sh.x + f.x * reach * shrink, shY - 0.12, sh.z + f.z * reach * shrink);
                rl.drawCapsule(sh, hand, 0.13 * shrink, 6, 4, flesh);
            }
            // A slack jaw hanging off the front of the skull: the head lolls.
            sphere(v3(hcx + f.x * headR * 0.85, headY - headR * 0.5, hcz + f.z * headR * 0.85), headR * 0.38, flesh);
        },
        // Archer: a drawn bow held out front — the ranged threat reads at a glance.
        .skeleton => {
            const bh = v3(x + f.x * (m.Radius + 0.25), MONSTER_TORSO_BASE + htop * 0.72 + bob, z + f.z * (m.Radius + 0.25));
            const bowCol = rgba(110, 78, 46, 255);
            rl.drawCylinderEx(bh, v3(bh.x - f.x * 0.14, bh.y + 0.62 * shrink, bh.z - f.z * 0.14), 0.06, 0.02, 5, bowCol);
            rl.drawCylinderEx(bh, v3(bh.x - f.x * 0.14, bh.y - 0.62 * shrink, bh.z - f.z * 0.14), 0.06, 0.02, 5, bowCol);
            // While the shot telegraphs, an arrow sits nocked and draws back — the
            // red beam says a shot is coming; the arrow says from where.
            if (m.windup > 0) {
                const pull = m.windupProgress();
                const nock = v3(bh.x - f.x * (0.2 + 0.3 * pull), bh.y, bh.z - f.z * (0.2 + 0.3 * pull));
                rl.drawCylinderEx(nock, v3(bh.x + f.x * 0.3, bh.y, bh.z + f.z * 0.3), 0.03, 0.03, 4, rgba(140, 108, 70, 255));
                rl.drawCylinderEx(v3(bh.x + f.x * 0.3, bh.y, bh.z + f.z * 0.3), v3(bh.x + f.x * 0.42, bh.y, bh.z + f.z * 0.42), 0.055, 0.0, 4, rgba(225, 220, 200, 255));
            }
            // Bony shoulder knobs so the pale frame looks skeletal, not smooth.
            for ([_]f32{ -1, 1 }) |s| {
                sphere(v3(x + right.x * m.Radius * 0.85 * s, MONSTER_TORSO_BASE + htop * 0.85 + bob, z + right.z * m.Radius * 0.85 * s), 0.14 * shrink, lerpColor(col, rl.Color.white, 0.15));
            }
            // Ribcage: three darker bands arced across the front of the frame — the
            // one detail that says "bones" instead of "pale ghost" at gameplay zoom.
            const ribCol = lerpColor(col, rl.Color.black, 0.35);
            for ([_]f32{ 0.42, 0.58, 0.74 }) |rf| {
                const ry = MONSTER_TORSO_BASE + htop * rf + bob;
                rl.drawCylinderEx(
                    v3(x + f.x * m.Radius * 0.55 - right.x * m.Radius * 0.68, ry, z + f.z * m.Radius * 0.55 - right.z * m.Radius * 0.68),
                    v3(x + f.x * m.Radius * 0.55 + right.x * m.Radius * 0.68, ry, z + f.z * m.Radius * 0.55 + right.z * m.Radius * 0.68),
                    0.035 * shrink,
                    0.035 * shrink,
                    4,
                    ribCol,
                );
            }
        },
        // Brute: mountainous shoulder boulders, a pair of ivory tusks, and thick
        // knuckle-dragging arms planted ahead — the gorilla stance sells the mass.
        .brute => {
            const shY = MONSTER_TORSO_BASE + htop * 0.78 + bob;
            for ([_]f32{ -1, 1 }) |s| {
                sphere(v3(x + right.x * m.Radius * 1.05 * s, shY, z + right.z * m.Radius * 1.05 * s), m.Radius * 0.52 * shrink, dark);
            }
            for ([_]f32{ -1, 1 }) |s| {
                const sh = v3(x + right.x * m.Radius * 1.05 * s, shY - 0.1, z + right.z * m.Radius * 1.05 * s);
                const fist = v3(x + right.x * m.Radius * 1.2 * s + f.x * m.Radius * 0.7, 0.24 * shrink, z + right.z * m.Radius * 1.2 * s + f.z * m.Radius * 0.7);
                rl.drawCapsule(sh, fist, m.Radius * 0.2 * shrink, 6, 4, dark);
                sphere(fist, m.Radius * 0.28 * shrink, dark);
            }
            for ([_]f32{ -1, 1 }) |s| {
                const tb = v3(hcx + f.x * headR * 0.8 + right.x * headR * 0.62 * s, headY - headR * 0.25, hcz + f.z * headR * 0.8 + right.z * headR * 0.62 * s);
                rl.drawCylinderEx(tb, v3(tb.x + f.x * 0.14, tb.y + 0.32 * shrink, tb.z + f.z * 0.14), 0.075 * shrink, 0.0, 5, rgba(228, 218, 190, 255));
            }
        },
    }

    // Champions wear a crown of horns — visible from any angle, unmistakable.
    if (m.boss) {
        var i: i32 = 0;
        while (i < 4) : (i += 1) {
            const a = @as(f32, @floatFromInt(i)) * (std.math.tau / 4.0) + 0.4;
            const cb = v3(hcx + cosf(a) * headR * 0.7, headY + headR * 0.55, hcz + sinf(a) * headR * 0.7);
            rl.drawCylinderEx(cb, v3(cb.x + cosf(a) * 0.1, cb.y + 0.42 * shrink, cb.z + sinf(a) * 0.1), 0.08 * shrink, 0.0, 5, rgba(60, 44, 40, 255));
        }
    }
}

// A dynamic body is worth drawing when it sits inside the torch's CURRENT lit disc
// (torchR — the breathing radius uploaded to the shader this frame, always <=
// TORCH_RADIUS), or when a live fireball is flying past close enough to light it out
// in the dark. Gated at the live lit radius (not the padded CULL) so bodies never
// linger as dim silhouettes on explored-but-dark ground: fog of war shows terrain
// memory in the "seen" band, never monsters or loot. The static scene mesh, by
// contrast, is always drawn in full.
fn bodyVisible(pos: rl.Vector3, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) bool {
    // Squared compares: this is the most-called cull test (every monster/loot, in
    // each of the 2-3 draw passes), and it's a pure threshold — no @sqrt needed.
    if (dist2XZ(pos, lightXZ) <= torchR * torchR) return true;
    return fp.intensity > 0 and dist2XZ(pos, fp.pos) <= fp.radius * fp.radius;
}

// Depth pass: living bodies visible this frame cast. Bodies neither near the torch
// nor lit by the fireball render black anyway, so there's no point shadowing them.
fn drawMonstersCast(ms: []const Monster, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (m.dying) continue;
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        drawMonsterBody(m);
    }
}

fn drawMonstersLit(ms: []const Monster, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        drawMonsterBody(m);
    }
}

// Emissive pass (no shadow): glowing eyes + the red attack telegraph + boss ring +
// the hover highlight under the monster the cursor (or pad aim) has picked out.
fn drawMonstersFX(ms: []const Monster, lightXZ: rl.Vector3, pPos: rl.Vector3, torchR: f32, fp: tl.FireParams, hoverID: i32, t: f32) void {
    for (ms) |*m| {
        if (m.dying or !m.alive()) continue;
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        // Lift this monster's FX (rings, glints, eyes) onto its terrain height;
        // anything aimed at the PLAYER must compensate back out of this frame.
        rl.gl.rlPushMatrix();
        defer rl.gl.rlPopMatrix();
        rl.gl.rlTranslatef(0, m.Pos.y, 0);
        if (m.id == hoverID) {
            const pulse = 0.12 * sinf(t * 6);
            rl.drawCircle3D(v3(m.Pos.x, 0.05, m.Pos.z), m.Radius + 0.3 + pulse, v3(1, 0, 0), 90, rgba(255, 245, 220, 210));
        }
        if (m.boss) {
            rl.drawCircle3D(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.4, v3(1, 0, 0), 90, rgba(255, 60, 60, 200));
            rl.drawCircle3D(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.55 + 0.1 * sinf(t * 3), v3(1, 0, 0), 90, rgba(255, 60, 60, 90));
        }
        if (m.windup > 0) {
            const tp = m.windupProgress();
            const a = mathx.u8f(clampF(110 + 130 * tp, 0, 255));
            if (m.Ranged) {
                // Aim the threat beam at the player's true elevation (compensating
                // for this monster's lifted frame), so it climbs up at a rampart.
                rl.drawCylinderEx(v3(m.Pos.x, 1.2, m.Pos.z), v3(pPos.x, pPos.y - m.Pos.y + 0.3, pPos.z), 0.05, 0.05, 4, rgba(255, 70, 50, a));
            } else {
                // The kill zone fills in as the blow comes down: a translucent red
                // disc swelling to the true reach, ringed by the hard edge.
                const rr = meleeReach(m.atkRange, playermod.radius);
                rl.drawCylinderEx(v3(m.Pos.x, 0.015, m.Pos.z), v3(m.Pos.x, 0.045, m.Pos.z), rr * tp, rr * tp, 24, rgba(255, 50, 30, mathx.u8f(26 + 44 * tp)));
                rl.drawCircle3D(v3(m.Pos.x, 0.09, m.Pos.z), rr, v3(1, 0, 0), 90, rgba(255, 60, 40, a));
                rl.drawCircle3D(v3(m.Pos.x, 0.09, m.Pos.z), rr * tp, v3(1, 0, 0), 90, rgba(255, 100, 50, a));
            }
        }
        // The pib knife catches the torchlight: a white star twinkling at the point
        // whenever the pig is in view, flaring hard as the strike comes down. The
        // knife IS the pib's telegraph — you should never lose track of it.
        if (m.Kind == .fallen) {
            const tp = m.windupProgress();
            const tip = pibKnifeTip(pibGrip(m));
            const tw = 0.7 + 0.3 * sinf(t * 9 + m.Pos.x * 3 + m.Pos.z * 5); // idle twinkle
            sphere(tip, (0.035 + 0.07 * tp) * tw, rgba(255, 255, 245, 255));
            sphere(tip, (0.1 + 0.15 * tp) * tw, rgba(255, 250, 220, mathx.u8f(40 + 110 * tp)));
        }
        const headY = monsterHeadY(m, 1);
        const f = mathx.orFacing(m.Facing, 0, 1);
        const right = mathx.perpXZ(f);
        const eyeCol = if (m.windup > 0) rgba(255, 70, 40, 255) else rgba(255, 210, 60, 255);
        // Eyes ride the same forward-shifted head center the body pass drew.
        const eyeFwd = m.Radius * 0.5 + monsterHeadFwd(m);
        for ([_]f32{ -1, 1 }) |s| {
            const e = v3(m.Pos.x + f.x * eyeFwd + right.x * m.Radius * 0.3 * s, headY + 0.02, m.Pos.z + f.z * eyeFwd + right.z * m.Radius * 0.3 * s);
            sphere(e, 0.07, eyeCol);
        }
    }
}

// Pick the fireball that lights the scene: the first live player bolt. Its light is
// modeled overhead (FIRE_HEIGHT above the terrain under the bolt) so the downward
// shadow map is well-oriented, with a warm colour and a gentle flame flicker.
// intensity 0 => no fireball, light disabled.
fn fireLight(g: *Game, t: f32) tl.FireParams {
    for (g.projs.items()) |*pr| {
        if (!pr.FromPlayer) continue;
        const flicker = 0.85 + 0.15 * sinf(t * 27);
        const gy = g.w.groundY(pr.Pos.x, pr.Pos.z);
        return .{
            .pos = v3(pr.Pos.x, gy + FIRE_HEIGHT, pr.Pos.z),
            .radius = FIRE_RADIUS,
            .color = v3(1.0, 0.55, 0.22),
            .intensity = 1.7 * flicker,
            .groundRef = gy,
        };
    }
    return .{ .pos = mathx.zero3, .radius = FIRE_RADIUS, .color = mathx.zero3, .intensity = 0 };
}

fn drawProjectiles(projs: *ProjList, t: f32) void {
    for (projs.items()) |*pr| {
        if (pr.FromPlayer) {
            // Firebolt: a white-hot heart inside a flickering orange corona, with a
            // tapering flame tongue trailing behind. The spark trail is particles.
            const flick = 1 + 0.16 * sinf(t * 31 + pr.Pos.x * 5 + pr.Pos.z * 3);
            const tail = v3(pr.Pos.x - pr.Vel.x * 0.055, pr.Pos.y + 0.1, pr.Pos.z - pr.Vel.z * 0.055);
            rl.drawCylinderEx(tail, pr.Pos, 0.04, pr.Radius * 0.75, 6, rgba(255, 120, 30, 120));
            sphere(pr.Pos, pr.Radius * 0.95 * flick, rgba(255, 110, 25, 95));
            sphere(pr.Pos, pr.Radius * 0.6 * flick, rgba(255, 180, 60, 210));
            sphere(pr.Pos, pr.Radius * 0.32, rgba(255, 246, 205, 255));
        } else {
            // Arrow: a real shaft — dark wood, pale bone head, grey fletching — laid
            // along its flight, far more legible (and menacing) than a floating ball.
            const inv = 1.0 / maxF(lenXZ(pr.Vel), 1e-4);
            const dx = pr.Vel.x * inv;
            const dz = pr.Vel.z * inv;
            const nock = v3(pr.Pos.x - dx * 0.5, pr.Pos.y, pr.Pos.z - dz * 0.5);
            const tip = v3(pr.Pos.x + dx * 0.28, pr.Pos.y, pr.Pos.z + dz * 0.28);
            rl.drawCylinderEx(nock, tip, 0.035, 0.035, 5, rgba(120, 90, 60, 255));
            rl.drawCylinderEx(tip, v3(tip.x + dx * 0.16, tip.y, tip.z + dz * 0.16), 0.07, 0.0, 5, rgba(225, 220, 200, 255));
            rl.drawCylinderEx(nock, v3(nock.x + dx * 0.16, nock.y, nock.z + dz * 0.16), 0.09, 0.02, 4, rgba(200, 200, 210, 220));
        }
    }
}

fn drawLoot(lootList: *std.ArrayList(LootDrop), lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) void {
    for (lootList.items) |*d| {
        if (!bodyVisible(d.Pos, lightXZ, torchR, fp)) continue;
        // Lift each drop (beam, pool, ring, item) onto the ground it fell on.
        rl.gl.rlPushMatrix();
        defer rl.gl.rlPopMatrix();
        rl.gl.rlTranslatef(0, d.Pos.y, 0);
        const y = 0.4 + 0.12 * sinf(d.bob);
        // The Diablo promise: a soft shaft of light stands over every drop, so loot
        // reads across the floor at a glance. Emissive pass — it glows, breathing
        // slowly, in the drop's own color.
        const beamCol = switch (d.Kind) {
            .gold => theme.goldColor,
            .health_potion => theme.healthColor,
            .mana_potion => theme.manaColor,
        };
        const pulse = 0.7 + 0.3 * sinf(d.bob * 0.7);
        rl.drawCylinderEx(v3(d.Pos.x, 0.05, d.Pos.z), v3(d.Pos.x, 2.0, d.Pos.z), 0.05, 0.012, 6, mathx.withAlpha(beamCol, mathx.u8f(90 * pulse)));
        rl.drawCylinderEx(v3(d.Pos.x, 0.05, d.Pos.z), v3(d.Pos.x, 1.3, d.Pos.z), 0.14, 0.02, 6, mathx.withAlpha(beamCol, mathx.u8f(34 * pulse)));
        // From the high iso camera the beam foreshortens to a dot, so the floor does
        // the talking: a soft glow pool plus a crisp ring, pulsing together.
        rl.drawCylinderEx(v3(d.Pos.x, 0.012, d.Pos.z), v3(d.Pos.x, 0.03, d.Pos.z), 0.45, 0.45, 20, mathx.withAlpha(beamCol, mathx.u8f(28 * pulse)));
        rl.drawCircle3D(v3(d.Pos.x, 0.04, d.Pos.z), 0.4 + 0.05 * sinf(d.bob), v3(1, 0, 0), 90, mathx.withAlpha(beamCol, mathx.u8f(140 * pulse)));
        switch (d.Kind) {
            .gold => {
                // A nugget pile on the floor rather than one hovering ball.
                sphere(v3(d.Pos.x, 0.14, d.Pos.z), 0.17, theme.goldColor);
                sphere(v3(d.Pos.x + 0.18, 0.1, d.Pos.z + 0.08), 0.11, lerpColor(theme.goldColor, rl.Color.black, 0.25));
                sphere(v3(d.Pos.x - 0.15, 0.1, d.Pos.z - 0.11), 0.12, lerpColor(theme.goldColor, rl.Color.white, 0.25));
            },
            .health_potion, .mana_potion => {
                // A corked flask that bobs on the spot: bulb, bright neck, cork.
                const col = if (d.Kind == .health_potion) theme.healthColor else theme.manaColor;
                rl.drawCapsule(v3(d.Pos.x, y - 0.08, d.Pos.z), v3(d.Pos.x, y + 0.1, d.Pos.z), 0.17, 8, 6, col);
                rl.drawCylinderEx(v3(d.Pos.x, y + 0.1, d.Pos.z), v3(d.Pos.x, y + 0.28, d.Pos.z), 0.06, 0.05, 8, lerpColor(col, rl.Color.white, 0.4));
                rl.drawCylinderEx(v3(d.Pos.x, y + 0.28, d.Pos.z), v3(d.Pos.x, y + 0.35, d.Pos.z), 0.075, 0.07, 8, rgba(150, 112, 70, 255));
            },
        }
    }
}

pub fn drawPortal(w: *const world.World, t: f32) void {
    const pp = w.PortalPos;
    if (!w.PortalOpen) {
        // Dormant: a dark stone dais with a faint rune ring that slowly pulses,
        // promising something will happen here. A dim heart-ember smolders at the
        // center — banked, waiting to be fed.
        rl.drawCylinderEx(v3(pp.x, 0.02, pp.z), v3(pp.x, 0.06, pp.z), 2.0, 2.0, 24, rgba(42, 42, 58, 220));
        const pulse = mathx.u8f(70 + 45 * sinf(t * 1.4));
        rl.drawCircle3D(v3(pp.x, 0.09, pp.z), 1.55, v3(1, 0, 0), 90, rgba(110, 100, 170, pulse));
        rl.drawCircle3D(v3(pp.x, 0.09, pp.z), 1.15, v3(1, 0, 0), 90, rgba(110, 100, 170, pulse / 2));
        sphere(v3(pp.x, 0.18, pp.z), 0.11 + 0.02 * sinf(t * 1.4), rgba(120, 105, 210, pulse));
        sphere(v3(pp.x, 0.18, pp.z), 0.26, rgba(120, 105, 210, pulse / 4));
        return;
    }
    // Open: a violet vortex built from AIR, not solids — a glowing dais, two helix
    // strands of bright motes corkscrewing up a tapering throat, and thin breathing
    // rim rings. (Stacked translucent cylinders read as one opaque blob from the iso
    // camera; points and lines stay airy.)
    rl.drawCylinderEx(v3(pp.x, 0.02, pp.z), v3(pp.x, 0.05, pp.z), 2.3, 2.3, 28, rgba(70, 50, 130, 150));
    rl.drawCylinderEx(v3(pp.x, 0.05, pp.z), v3(pp.x, 0.08, pp.z), 1.9, 1.9, 28, rgba(120, 90, 220, 100));
    var strand: i32 = 0;
    while (strand < 2) : (strand += 1) {
        const sPh: f32 = @floatFromInt(strand);
        var s: i32 = 0;
        while (s < 14) : (s += 1) {
            const f: f32 = @as(f32, @floatFromInt(s)) / 13.0;
            const ang = t * 2.6 + f * 12.0 + sPh * std.math.pi;
            const r = (1.55 - f * 0.95) + 0.08 * sinf(t * 3 + f * 9);
            const y = 0.12 + f * 3.1;
            const pos = v3(pp.x + cosf(ang) * r, y, pp.z + sinf(ang) * r);
            const c = lerpColor(rgba(150, 170, 255, 255), rgba(230, 160, 255, 240), f);
            sphere(pos, 0.17 * (1 - f * 0.4), c);
            sphere(pos, 0.32 * (1 - f * 0.4), mathx.withAlpha(c, 70)); // soft halo
        }
    }
    // Breathing rim rings anchor the throat to the dais.
    rl.drawCircle3D(v3(pp.x, 0.1, pp.z), 1.6 + 0.08 * sinf(t * 2.1), v3(1, 0, 0), 90, rgba(200, 170, 255, 190));
    rl.drawCircle3D(v3(pp.x, 0.1, pp.z), 1.25 + 0.06 * sinf(t * 2.1 + 1.5), v3(1, 0, 0), 90, rgba(160, 130, 255, 130));
    // A sky-beam over the open gate — the arena's one landmark, readable across the
    // whole dark from the iso camera as a soft violet column over the dais.
    rl.drawCylinderEx(v3(pp.x, 0.1, pp.z), v3(pp.x, 8.0, pp.z), 1.05, 0.28, 12, rgba(150, 110, 255, 26));
    rl.drawCylinderEx(v3(pp.x, 0.1, pp.z), v3(pp.x, 5.4, pp.z), 0.5, 0.12, 10, rgba(200, 170, 255, 44));
    // Three rune-sparks patrol the rim, counter-rotating against the helix.
    var k: i32 = 0;
    while (k < 3) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ang = -t * 1.3 + kf * (std.math.tau / 3.0);
        const rp = v3(pp.x + cosf(ang) * 2.0, 0.3 + 0.1 * sinf(t * 2.2 + kf * 2.1), pp.z + sinf(ang) * 2.0);
        sphere(rp, 0.08, rgba(225, 200, 255, 235));
        sphere(rp, 0.2, rgba(180, 140, 255, 70));
    }
}

// Fireflies: a handful of tiny blinking lights adrift in the darkness OUTSIDE the
// torch disc. Pure function of time + index (no state, no reveal — they're air, like
// monster eyes), each wandering a slow lissajous around a fixed seat in the arena.
// They make the unexplored black read as a living night instead of a void.
fn drawFireflies(g: *const Game, t: f32) void {
    // Per-area swarm personality: meadow-green over the moor, pale wisps on the cold
    // plains, sickly green under the dark wood, violet grave-lights in the catacombs.
    const cols = [_]rl.Color{
        rgba(180, 220, 100, 255),
        rgba(170, 205, 255, 255),
        rgba(205, 210, 120, 255),
        rgba(150, 235, 110, 255),
        rgba(165, 150, 255, 255),
    };
    const col = cols[g.areaIndex % cols.len];
    const n: usize = if (g.areaIndex == 3) 26 else 16; // the Dark Wood teems
    const halfW = g.w.HalfW - 4;
    const halfD = g.w.HalfD - 4;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        // Golden-ratio scatter: even coverage with no two seats aligned.
        const hx = (@mod(iff * 0.7548777, 1.0) * 2 - 1) * halfW;
        const hz = (@mod(iff * 0.5698403, 1.0) * 2 - 1) * halfD;
        const pos = v3(
            hx + sinf(t * 0.31 + iff * 2.1) * 1.8,
            0.65 + 0.45 * sinf(t * 0.23 + iff * 1.3) + @mod(iff, 3.0) * 0.3,
            hz + cosf(t * 0.27 + iff * 1.7) * 1.8,
        );
        // Inside the lit disc a firefly's glow would fight the torch; let it hide.
        if (distXZ(pos, g.p.Pos) < TORCH_RADIUS + 1.5) continue;
        const blink = 0.5 + 0.5 * sinf(t * (0.9 + @mod(iff * 0.37, 0.8)) + iff * 4.7);
        const a = 35 + 120 * blink * blink;
        sphere(pos, 0.045, mathx.withAlpha(col, mathx.u8f(a)));
        sphere(pos, 0.12, mathx.withAlpha(col, mathx.u8f(a * 0.25)));
    }
}

// drawWorld renders one frame of the 3D scene through the frozen torch pipeline.
fn drawWorld(g: *Game) void {
    var cam = g.rig.cam;
    if (g.shake > 0) {
        const amp = g.shake * 0.7;
        cam.position.x += amp * sinf(g.elapsed * 63);
        cam.position.y += amp * cosf(g.elapsed * 71);
    }

    const t = g.elapsed;
    // Torch breathing: the lit disc contracts a few percent on two beat frequencies so
    // the light feels alive. Downward-only (never past TORCH_RADIUS) so bodies culled at
    // exactly TORCH_RADIUS can never sit outside the drawn light.
    const breath = 1.0 - 0.022 * (0.5 + 0.5 * sinf(t * 7.1)) - 0.014 * (0.5 + 0.5 * sinf(t * 13.7));
    // The light hangs over the CARRIED flame (g.torchXZ), not over the hero's head —
    // shadows lean away from the torch hand and swing around as the hero turns. It
    // rides the LOCAL walkable ground, so a rampart lifts the whole rig with you.
    const pGroundY = g.w.groundY(g.p.Pos.x, g.p.Pos.z);
    const lp = tl.LightParams{ .pos = v3(g.torchXZ.x, pGroundY + TORCH_HEIGHT, g.torchXZ.z), .radius = TORCH_RADIUS * breath, .groundRef = pGroundY };
    // Every body-draw gate measures from the light's own ground point, so the culled
    // set and the drawn light disc can never diverge.
    const lightGround = v3(g.torchXZ.x, 0, g.torchXZ.z);
    const fp = fireLight(g, t);
    const ms = g.liveMonsters();
    const drawHero = g.p.alive();

    // --- torch depth pass (obstacle mesh + nearby monsters + player cast) ---
    g.torch.beginShadowPass(lp);
    g.sceneMesh.drawDepth();
    drawMonstersCast(ms, lightGround, lp.radius, fp);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endShadowPass();

    // --- fireball depth pass (only when a bolt is live) ---
    if (fp.intensity > 0) {
        g.torch.beginFireShadowPass(fp);
        g.sceneMesh.drawDepth();
        drawMonstersCast(ms, lightGround, lp.radius, fp);
        if (drawHero) drawHeroBody(&g.p);
        g.torch.endFireShadowPass();
    }

    // --- main pass ---
    rl.beginDrawing();
    rl.clearBackground(rgba(16, 16, 22, 255));
    g.torch.applyUniforms(cam, lp);
    g.torch.applyFireUniforms(fp);
    g.torch.applyFogUniforms(.{ .texId = @intCast(g.fog.tex.id), .halfW = g.fog.halfW, .halfD = g.fog.halfD });
    rl.beginMode3D(cam);
    g.torch.beginScene();
    // beginScene bound the shadow map on slot 10 and left it active; reset to 0 so
    // immediate-mode texture0 binds land on slot 0, not on the shadow map.
    rl.gl.rlActiveTextureSlot(0);
    g.sceneMesh.drawScene();
    rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(g.w.HalfW * 2, g.w.HalfD * 2), g.w.Ground);
    drawWalls(&g.w);
    drawMonstersLit(ms, lightGround, lp.radius, fp);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endScene();
    if (drawHero) drawHeroFX(&g.p, t);
    drawMonstersFX(ms, lightGround, g.p.Pos, lp.radius, fp, g.hoverMonster, t);
    drawLoot(&g.lootList, lightGround, lp.radius, fp);
    drawProjectiles(&g.projs, t);
    drawPortal(&g.w, t);
    drawFireflies(g, t);
    g.parts.draw();
    rl.endMode3D();
}

pub fn run(shot: bool) void {
    // 4x MSAA smooths every polygon edge in the scene (the biggest overall-fidelity
    // win); set before initWindow or the GL context ignores it.
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_hidden = shot });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    // Esc is NAVIGATION (menus, editor modals, playtest exit) — raylib's default
    // exit key is Esc, which would kill the window instead. Quitting goes through
    // the menu's Quit item (g.quit) or the close button only.
    rl.setExitKey(.null);
    // Uncapped: no setTargetFPS. setTargetFPS paces by OS sleep, whose ~15.6ms Windows
    // timer granularity makes a 60fps target periodically oversleep into a dropped frame
    // (a "chug" despite ample headroom). Running free removes that jitter. To re-cap
    // smoothly later, prefer .vsync_hint (GPU flip pacing) over setTargetFPS.

    var g = Game.init(if (shot) 1234 else mathx.timeSeed()) catch return;
    defer g.deinit();
    defer g.rumble.stop(); // never leave a motor latched on after the window closes

    // Screenshot harness: skip the menu, sweep a few vantage points — the RAMPART
    // (hero on high ground, monsters at the cliff base), arena center, and the
    // (forced-open) portal so its FX show. The camera snaps to each teleport, then
    // a dozen frames run so fog reveals, particles spawn, and the smoothed rig
    // settles before the shutter clicks.
    const sweep = [_]rl.Vector3{
        mathx.ground(31.5, 20), // atop the Blood Moor rampart (ledge spans x 26.., z 4..30)
        mathx.ground(0, 0),
        mathx.ground(g.w.PortalPos.x, g.w.PortalPos.z + 5),
    };
    if (shot) {
        g.scene = .playing;
        g.p.Pos = sweep[0];
        g.rig.snap(g.p.Pos);
        g.torchXZ = torchFlameWorld(&g.p);
        // Drain the resources partway so the orbs photograph with a visible liquid
        // surface (a full orb hides the meniscus + fill line entirely).
        g.p.HP = g.p.MaxHP * 0.62;
        g.p.Mana = g.p.MaxMana * 0.45;
        // Rampart tableau: a pack milling at the cliff base below the hero, and a
        // firebolt frozen mid-descent — the "pew from the high ground" money shot.
        g.p.Facing = dirXZ(g.p.Pos, v3(22, 0, 15));
        g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(22.5, 13.5)));
        g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(20.5, 17)));
        g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(23.5, 19)));
        const boltFrom = v3(31.5, 2.4, 20);
        const boltTo = v3(21, 0, 13.5);
        g.projs.add(projectile.newFirebolt(boltFrom, dirXZ(boltFrom, boltTo), 20, aimYVel(2.4 + projectile.fireboltMuzzleDY, 0.9, distXZ(boltFrom, boltTo), projectile.fireboltSpeed)));
    }
    var frame: i32 = 0;
    var shotIdx: usize = 0;

    while (!rl.windowShouldClose() and !g.quit) {
        const dt = rl.getFrameTime();
        g.elapsed += dt; // advances in every scene (drives flicker/animation)

        // Alt+Enter anywhere: toggle fullscreen-windowed (borderless).
        const altHeld = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
        if (altHeld and rl.isKeyPressed(.enter)) {
            setDisplayMode(&g, if (g.displayMode == .windowed) .borderless else .windowed);
        }

        switch (g.scene) {
            .menu => {
                const n: i32 = if (g.menuMode == .root) menuRootItems.len else MENU_OPTIONS_COUNT;
                if (rl.isKeyPressed(.down) or rl.isKeyPressed(.s)) g.menuSel = @mod(g.menuSel + 1, n);
                if (rl.isKeyPressed(.up) or rl.isKeyPressed(.w)) g.menuSel = @mod(g.menuSel - 1 + n, n);
                if ((rl.isKeyPressed(.enter) and !altHeld) or rl.isKeyPressed(.space) or padStartPressed()) menuActivate(&g, g.menuSel);
                if (g.menuMode == .options) {
                    if (rl.isKeyPressed(.escape)) {
                        g.menuMode = .root;
                        g.menuSel = MENU_OPTIONS_IDX;
                    }
                    if (g.menuSel == 0 and (rl.isKeyPressed(.left) or rl.isKeyPressed(.right))) {
                        cycleDisplayMode(&g, rl.isKeyPressed(.right));
                    }
                }
                g.rig.follow(g.p.Pos, dt); // let the backdrop drift
            },
            .playing => {
                if (rl.isKeyPressed(.escape) or padStartPressed()) {
                    if (g.playtest) endPlaytest(&g) else g.scene = .menu;
                }
                if (g.scene == .playing) updatePlaying(&g, dt);
            },
            .dead => {
                if (rl.isKeyPressed(.r) or padStartPressed()) {
                    if (g.playtest) endPlaytest(&g) else g.startRun();
                }
                g.parts.update(dt); // let the killing blow's burst finish playing
            },
            .victory => {
                if (rl.isKeyPressed(.enter) or padStartPressed()) g.startRun();
            },
            .editor => editor.update(&g, dt),
        }

        // Drive rumble every frame across all scenes so envelopes always decay to
        // silence (the death rumble swells on into the death screen). Silent while
        // paused, with no controller, or in the HEADLESS screenshot harness — an
        // automated --gameshot run must never buzz a connected pad on the desk.
        g.rumble.update(dt, !shot and rl.isGamepadAvailable(PAD) and !g.paused);

        if (g.scene == .editor) {
            editor.draw(&g);
            editor.drawOverlay(&g);
            rl.endDrawing();
        } else {
            drawWorld(&g);
            hudx.draw(&g);
            rl.endDrawing();
        }

        if (shot) {
            frame += 1;
            if (frame >= 14) {
                frame = 0;
                std.fs.cwd().makePath("shots") catch {};
                var buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&buf, "shots/shot_game_{d}.png", .{shotIdx + 1}) catch break;
                rl.takeScreenshot(name);
                shotIdx += 1;
                if (shotIdx >= sweep.len) {
                    // After the world vantages, photograph each full-screen scene
                    // (the editor last — entered properly so it loads + applies).
                    const extraScenes = [_]Scene{ .menu, .dead, .victory, .editor };
                    const ei = shotIdx - sweep.len;
                    if (ei >= extraScenes.len) break;
                    if (extraScenes[ei] == .editor) {
                        g.areaIndex = 0;
                        editor.enter(&g);
                    } else {
                        g.scene = extraScenes[ei];
                    }
                    continue;
                }
                g.p.Pos = sweep[shotIdx];
                g.rig.snap(g.p.Pos);
                g.torchXZ = torchFlameWorld(&g.p); // teleport the light with the hero
                g.banner.time = 0; // the area banner would sit right over the subjects
                if (shotIdx == 1) {
                    // Family portrait: one of each kind posed around the hero, angled
                    // three-quarter to the camera, zoomed in — one shot verifies
                    // every silhouette.
                    const px = g.p.Pos.x;
                    const pz = g.p.Pos.z;
                    g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(px - 3, pz - 1)));
                    g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(px + 3, pz - 1.5)));
                    g.spawn(monster.makeMonster(.skeleton, 0, &g.rng, mathx.ground(px - 1, pz - 4)));
                    g.spawn(monster.makeMonster(.brute, 0, &g.rng, mathx.ground(px + 2.5, pz + 3)));
                    var mi = g.monsterCount - 4;
                    while (mi < g.monsterCount) : (mi += 1) {
                        g.monsters[mi].Facing = v3(-0.66, 0, 0.75);
                    }
                    // Pose the pib mid-windup so the portrait shows the knife raised
                    // (and its glint) — the whole point of the little menace.
                    g.monsters[g.monsterCount - 4].windup = g.monsters[g.monsterCount - 4].windupTime * 0.45;
                    // Engage the brute so the top-center enemy plate is in frame
                    // (updateAim re-derives hover each frame, but the attack target
                    // sticks — and the plate reads from it as its second priority).
                    g.p.targetMonster = g.monsters[g.monsterCount - 1].id;
                    // And one fresh corpse mid-fade, to verify the spreading blood pool.
                    g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(px + 0.6, pz + 4.6)));
                    g.monsters[g.monsterCount - 1].dying = true;
                    g.monsters[g.monsterCount - 1].HP = 0;
                    g.monsters[g.monsterCount - 1].deathTimer = monster.monster_death_fade * 0.5;
                    // A firebolt frozen mid-flight, to verify the bolt + its trail.
                    g.projs.add(projectile.newFirebolt(mathx.ground(px - 1.5, pz + 2.5), v3(-0.8, 0, 0.6), 20, 0));
                    // Ground loot just out of pickup range, to verify the drop beams.
                    g.lootList.append(.{ .Kind = .gold, .Pos = mathx.ground(px - 0.4, pz + 4.0), .Amount = 25 }) catch {};
                    g.lootList.append(.{ .Kind = .health_potion, .Pos = mathx.ground(px - 2.6, pz + 2.0), .Amount = 1 }) catch {};
                    g.rig.zoom = 2.2;
                    g.rig.snap(g.p.Pos);
                }
                if (shotIdx == sweep.len - 1) {
                    g.rig.zoom = 1.4;
                    g.rig.snap(g.p.Pos);
                    g.w.PortalOpen = true; // show the vortex...
                    // ...and clear the stage: anything camped on the portal hides it.
                    var wkeep: usize = 0;
                    for (g.liveMonsters()) |m2| {
                        if (distXZ(m2.Pos, g.w.PortalPos) > 12) {
                            g.monsters[wkeep] = m2;
                            wkeep += 1;
                        }
                    }
                    g.monsterCount = wkeep;
                }
            }
        }
    }
}
