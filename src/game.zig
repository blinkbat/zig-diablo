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
const stats = @import("stats.zig");
const input = @import("input.zig");
const loot = @import("loot.zig");
const cameramod = @import("camera.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");
const rumble = @import("rumble.zig");
const particles = @import("particles.zig");
const trigmod = @import("trigger.zig");

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

// Runtime spawn cap. Well below the authored worst case (map.MAX_PACKS *
// map.PACK_MEMBERS_MAX members + a boss); spawnPacks deploys the boss first, then drops
// rank-and-file once this fills, so an over-stuffed map never clears without a champion.
const MAX_MONSTERS = 512;
// Firebolt cooldown/crit come from the RPG layer: p.castRate, p.derived.critChance,
// stats.CRIT_MULT. See stats.zig / player.zig.

// Scuffed-earth dust for footsteps and dodges; one tint (alpha varies per use).
const DUST_COLOR = rgba(200, 172, 132, 255);

// Light tuning. The hero IS the light bearer — no drawn prop (owner 2026-07-17:
// hero carries no bow/torch so any playstyle reads true); the lamp hangs over him,
// smoothed via torchXZ. 4.5 is the height floor: lower breaks the shadow cam's
// 150-deg FOV clamp or stops clearing a zombie/brute head (~3.9) so they'd stop
// casting; only the boss crown (~4.9) pokes above.
const TORCH_HEIGHT = 4.5;
const TORCH_RADIUS = 11.0;

// Hero drawn scaled up about his feet (uniform, so normals stay valid). 1.22 makes
// the drawn torso fill the collision radius (playermod.radius 0.55).
const HERO_SCALE = 1.22;

// A live player fireball is its own moving light, following the bolt beyond the torch
// radius. Modeled overhead like the torch so its downward shadow map stays oriented.
const FIRE_HEIGHT = 3.5;
const FIRE_RADIUS = 7.0;
// Vision radius gating targeting/health bars/popups — the lit disc itself: you can only
// select (auto-nearest OR manual hover/stick) a foe you can actually see by torchlight.
// Held to TORCH_RADIUS, not the breathing radius, so edge selection stays stable rather
// than flickering with the torch. Body DRAWING gates on the frame's breathing radius
// (bodyVisible), always <= this, so nothing dynamic bleeds into the fog "seen" band.
const CULL = TORCH_RADIUS;

pub const DAMAGE_FLASH_DUR = 0.4;
pub const TOAST_DUR = 2.5;

// Area-name banner hold (seconds); level-up reuses the banner with a shorter hold.
const AREA_BANNER_DUR = 3.5;
const LEVELUP_BANNER_DUR = 2.2;

// Fixed-capacity projectile pool (arrows + firebolts); no allocator needed.
const ProjList = struct {
    buf: [1024]Projectile = undefined,
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

// A slain zombie's miasma: stationary poison cloud that ticks damage inside it.
// Fixed capacity; overflow drops the NEW cloud (needs 64 corpses gassing at once).
const MAX_GAS = 64;
const GAS_RADIUS = 2.2; // the DoT footprint — the drawn blobs must visually fill it
const GAS_LIFE = 7.0;
const GAS_GROW = 0.5; // seconds to billow to full size
const GAS_TICK = 0.45; // seconds between hurt pulses in a cloud
const GAS_DPS_FRAC = 0.3; // cloud dps as a fraction of the dead zombie's MaxDmg
// The miasma's green family in one block, spawn burst through hero cough, so the rot
// can be regraded without a six-site hunt. (The flask projectile keeps its own
// projectile.toxicColor — vial glass, not cloud.)
const GAS_BURST_COLOR = rgba(188, 228, 112, 230);
const GAS_WISP_COLOR = rgba(198, 235, 124, 190);
const GAS_STAIN_COLOR = rgba(52, 105, 28, 255); // alpha computed per frame at the draw
const GAS_HEART_COLOR = rgba(98, 175, 50, 255);
const GAS_BLOB_COLOR = rgba(72, 142, 38, 255);
const GAS_COUGH_COLOR = rgba(140, 180, 80, 200);

const GasCloud = struct {
    Pos: rl.Vector3 = mathx.zero3,
    life: f32 = 0,
    dps: f32 = 0,
    seed: f32 = 0, // per-cloud churn phase so neighbouring clouds don't boil in sync
    // Whose cloud: a zombie's miasma hurts the HERO; the hero's Toxic Flask hurts
    // MONSTERS. Same rendering + lifecycle, opposite victims.
    fromPlayer: bool = false,
};

// Fixed-capacity transient text field: format into an inline buffer with a countdown.
// Shared by the toast and area banner.
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

// Title menu root rows. RootItem names each slot so labels (hudx) and dispatch
// (menuActivate) stay in order; the assert pins the label array 1:1 with the enum.
pub const RootItem = enum(i32) { adventure, editor, options, quit };
pub const menuRootItems = [_][:0]const u8{ "Adventure", "Editor", "Options", "Quit" };
comptime {
    std.debug.assert(menuRootItems.len == @typeInfo(RootItem).@"enum".fields.len);
}

// Options screen entry/return lands the cursor on the Options row; index derives from the enum.
pub const MENU_OPTIONS_IDX: i32 = @intFromEnum(RootItem.options);
// Options screen rows, same enum discipline as RootItem: labels (hudx), dispatch, and
// nav-wrap count all follow this — add a row in one place.
pub const OptionsItem = enum(i32) { display, debug, back };
pub const MENU_OPTIONS_COUNT: i32 = @typeInfo(OptionsItem).@"enum".fields.len;

// Stat sheet rows: the six attributes (stats.zig display order) then the RANKABLE skills.
// Nav-wrap and hudx layout derive their count from these. Consumables (potions) are
// Skills but carry no rank, so they're excluded — the assert pins exactly that.
pub const sheetSkills = [_]playermod.Skill{ .melee, .firebolt, .dodge };
comptime {
    var rankable = 0;
    for (playermod.Skill.all) |s| {
        if (s.rankable()) rankable += 1;
    }
    std.debug.assert(sheetSkills.len == rankable); // every rankable skill has a row...
    for (sheetSkills) |s| std.debug.assert(s.rankable()); // ...and only rankable skills do
}
pub const SHEET_ATTR_COUNT: i32 = @intCast(stats.Attribs.order.len);
pub const SHEET_ROW_COUNT: i32 = SHEET_ATTR_COUNT + @as(i32, @intCast(sheetSkills.len));

// Character screen pages. Stats = attributes/skills/derived (as before); Skills = the
// reassignable bar. Both keyboard and gamepad drive every page (see updateCharScreen).
pub const CharTab = enum { stats, skills };
// The Skills-loadout cursor lives in one of two zones: the button-slot row (choose which
// button you're setting) or the skill pool below it (choose the skill to bind there).
pub const SkillZone = enum { slots, pool };

// Where the persisted loadout lives (CWD, like lightlog.txt). A small `version:`-headed
// config; see playermod.SkillBar.save/load.
pub const SKILLBAR_PATH = "skillbar.cfg";

// Drive the open character screen. Controller-first: L1/R1 flip the page, the d-pad
// navigates, A confirms/cycles, B closes; keyboard mirrors each. Cancel persists the
// loadout on the way out.
fn updateCharScreen(g: *Game, altHeld: bool) void {
    if (input.charTabTogglePressed()) g.charTab = if (g.charTab == .stats) .skills else .stats;
    if (input.cancel()) {
        // On the Skills pool, B is "back one level" — return to the button row; a second B
        // (from the row) closes the screen. Everywhere else B closes.
        if (g.charTab == .skills and g.skillZone == .pool) {
            g.skillZone = .slots;
        } else {
            g.closeCharScreen();
        }
        return;
    }
    switch (g.charTab) {
        .stats => updateStatsTab(g, altHeld),
        .skills => updateSkillsTab(g, altHeld),
    }
}

// Step a d-pad menu cursor by `delta` (±1), wrapping within [0, n). One source so the
// off-by-one "+ n" before the modulo can't be fumbled per menu.
fn navWrap(sel: i32, delta: i32, n: i32) i32 {
    return @mod(sel + delta + n, n);
}

// Stats page: up/down move the row, A / right spends a point on it.
fn updateStatsTab(g: *Game, altHeld: bool) void {
    if (input.navDown()) g.sheetSel = navWrap(g.sheetSel, 1, SHEET_ROW_COUNT);
    if (input.navUp()) g.sheetSel = navWrap(g.sheetSel, -1, SHEET_ROW_COUNT);
    if (input.confirm(altHeld) or input.navRight()) {
        if (g.sheetSel < SHEET_ATTR_COUNT) {
            _ = g.p.allocAttr(stats.Attribs.order[@intCast(g.sheetSel)]);
        } else {
            _ = g.p.allocSkill(sheetSkills[@intCast(g.sheetSel - SHEET_ATTR_COUNT)]);
        }
    }
}

// Skills page: pick a button in the top slot row (left/right), drop into the pool below
// (down), browse every skill (d-pad), and A binds the focused skill onto the chosen
// button — pressing A on the skill already there clears the button (toggle). Up from the
// pool's top row returns to the slots. The mouse mirrors this in hudx (secondary path).
pub const SKILL_POOL_COLS = 5;
fn updateSkillsTab(g: *Game, altHeld: bool) void {
    const slots: i32 = playermod.SKILL_SLOTS;
    const count: i32 = playermod.Skill.count;
    const cols: i32 = SKILL_POOL_COLS;
    switch (g.skillZone) {
        .slots => {
            if (input.navLeft()) g.skillSel = navWrap(g.skillSel, -1, slots);
            if (input.navRight()) g.skillSel = navWrap(g.skillSel, 1, slots);
            // Drop into the pool; land the cursor on the button's current skill (if any)
            // so A immediately toggles it, else on the first chip.
            if (input.navDown() or input.confirm(altHeld)) {
                g.skillZone = .pool;
                // Land on the button's current skill (so A toggles it off), else chip 0.
                g.skillPoolSel = if (g.p.bar.slots[@intCast(g.skillSel)]) |s| poolIndexOf(s) else 0;
            }
        },
        .pool => {
            if (input.navLeft()) g.skillPoolSel = navWrap(g.skillPoolSel, -1, count);
            if (input.navRight()) g.skillPoolSel = navWrap(g.skillPoolSel, 1, count);
            if (input.navUp()) {
                if (g.skillPoolSel < cols) g.skillZone = .slots // back up to the button row
                else g.skillPoolSel -= cols;
            }
            if (input.navDown()) {
                if (g.skillPoolSel + cols < count) g.skillPoolSel += cols;
            }
            if (input.confirm(altHeld)) {
                const s = playermod.Skill.all[@intCast(g.skillPoolSel)];
                const slot: usize = @intCast(g.skillSel);
                // Toggle: the skill already on this button clears it; anything else binds
                // (assign pulls it off its old button, keeping each skill unique). You can
                // only bind a skill you OWN — an unowned one is locked until acquired.
                if (g.p.bar.slots[slot] == s) {
                    g.p.bar.assign(slot, null);
                } else if (g.p.owns(s)) {
                    g.p.bar.assign(slot, s);
                } else {
                    g.setToast("{s} is locked — acquire it first", .{s.label()});
                }
            }
        },
    }
}

// The pool draws player.Skill.all in order, so a skill's pool index is its position there.
fn poolIndexOf(s: playermod.Skill) i32 {
    for (playermod.Skill.all, 0..) |e, i| {
        if (e == s) return @intCast(i);
    }
    return 0;
}

// Toggle one raylib display latch on/off (windowed is the un-latched base state).
fn applyModeToggle(m: DisplayMode) void {
    switch (m) {
        .borderless => rl.toggleBorderlessWindowed(),
        .fullscreen => rl.toggleFullscreen(),
        .windowed => {},
    }
}

// Switch display mode, unwinding the active mode first (raylib toggles are on/off latches).
fn setDisplayMode(g: *Game, want: DisplayMode) void {
    if (g.displayMode == want) return;
    applyModeToggle(g.displayMode);
    applyModeToggle(want);
    g.displayMode = want;
}

pub fn cycleDisplayMode(g: *Game, fwd: bool) void {
    const n: i32 = @typeInfo(DisplayMode).@"enum".fields.len; // add a mode and the cycle covers it
    const cur: i32 = @intFromEnum(g.displayMode);
    const next: DisplayMode = @enumFromInt(navWrap(cur, if (fwd) 1 else -1, n));
    setDisplayMode(g, next);
}

// Activate a menu item (shared by keyboard Enter and mouse click in hudx).
pub fn menuActivate(g: *Game, idx: i32) void {
    if (g.menuMode == .options) {
        switch (@as(OptionsItem, @enumFromInt(idx))) {
            .display => cycleDisplayMode(g, true),
            .debug => toggleDebugLog(g),
            .back => {
                g.menuMode = .root;
                g.menuSel = MENU_OPTIONS_IDX;
            },
        }
        return;
    }
    // idx is a valid row; decode to the named slot and dispatch.
    switch (@as(RootItem, @enumFromInt(idx))) {
        // Resume a live run if one is paused behind the menu; otherwise start fresh.
        .adventure => if (g.canResume) {
            g.paused = false; // don't resume into a frozen (P-paused) world
            input.swallowHeldSlots(); // held menu-confirm (A) is slot 0's button
            g.scene = .playing;
        } else g.startRun(),
        .editor => editor.enter(g),
        .options => {
            g.menuMode = .options;
            g.menuSel = 0;
        },
        .quit => g.quit = true,
    }
}

// A melee monster's true reach: attack range + target radius + a small lunge. Strike
// check and drawn telegraph ring MUST share this so outside-the-ring is safe.
const MELEE_LUNGE = 0.35;

// Incoming-shot vertical band on a monster: centered MONSTER_HIT_FRAC up its height,
// half-height MONSTER_HIT_FRAC*Height plus a small pad. Mirrors the hero's hitY/hitHalf.
const MONSTER_HIT_FRAC = 0.55;
const MONSTER_HIT_PAD = 0.7;
fn meleeReach(atkRange: f32, targetRadius: f32) f32 {
    return baseReach(atkRange, targetRadius) + MELEE_LUNGE; // base reach plus the lunge, one formula
}

// Red a monster's BODY flushes toward through windup and swing (the ground rings,
// threat beam, and lit eyes each carry their own hostile red at their draw sites).
const THREAT_TINT = rgba(255, 80, 40, 255);

// Cool bright wash the SELECTED target's body flushes toward, so it reads as "this is who
// I'd hit" at a glance. A base tint (state tints like THREAT still override it), paired
// with the feet reticle in drawMonstersFX and the HUD plate.
const TARGET_TINT = rgba(180, 235, 255, 255);

// How far ahead of the zombie's radius its overhead slam lands. Shared by the dust-kick
// (resolveMonsterAttack) and the drawn fists (drawMonsterBody).
const ZOMBIE_SLAM_FWD = 0.7;

// Base strike reach: attack range + target radius (no lunge). One helper so the hero's
// chase-stop/hit check and the monster's melee-windup gate can't drift apart. (The actual
// blow — hero or monster — reaches MELEE_LUNGE farther; see meleeReach, which the drawn
// ring mirrors so the telegraph never lies.)
fn baseReach(atkRange: f32, targetRadius: f32) f32 {
    return atkRange + targetRadius;
}

// A swing just short of reach lunges the hero this far forward to connect, rather than
// whiffing at the edge. Small enough to read as a step, not a dash.
const MELEE_STEP: f32 = 0.6;

// Extra-skill footprints. Nova is a burst around the hero; Cleave sweeps a frontal arc
// out to the melee reach. CLEAVE_ARC_DOT is the cosine cutoff between facing and the
// direction to a foe — -0.15 ≈ a ~197° fan, so it catches flanking foes but not your back.
// The drawn sweep derives its half-angle from THIS dot (acos) per the telegraph rule:
// the steel must not understate the cone it hits.
const NOVA_RADIUS: f32 = 5.0;
const CLEAVE_ARC_DOT: f32 = -0.15;

// Max vertical gap counting as "comparable ground" for melee: strikes (both ways) and
// windup decisions all read this, so nobody swings across a cliff edge. Above
// world.STEP_MAX so a single ramp step is still in reach.
const SAME_GROUND_DY = 1.0;

// The "comparable ground" test itself — melee strikes (both ways), the windup gate, nova,
// and the gas clouds all read it, so nobody reaches across a cliff edge on a stale copy.
fn sameGroundY(ay: f32, by: f32) bool {
    return @abs(ay - by) < SAME_GROUND_DY;
}

// Low-poly sphere. raylib's drawSphere is 16x16 with per-call CPU trig; under a dark
// torch an 8x8 ball is indistinguishable at ~1/4 cost (scene drawn twice a frame).
fn sphere(pos: rl.Vector3, r: f32, col: rl.Color) void {
    rl.drawSphereEx(pos, r, 8, 8, col);
}

// Scale the model-view stack up about the hero's feet so every hero draw renders
// HERO_SCALE bigger; the translate carries base.y onto the terrain. Uniform scale
// only (rlgl doesn't re-transform normals — correct for uniform scale).
fn beginHeroScale(base: rl.Vector3) void {
    rl.gl.rlPushMatrix();
    rl.gl.rlTranslatef(base.x, base.y, base.z);
    rl.gl.rlScalef(HERO_SCALE, HERO_SCALE, HERO_SCALE);
    rl.gl.rlTranslatef(-base.x, 0, -base.z);
}

// The light's world anchor: the hero himself (XZ; the lamp height comes from
// TORCH_HEIGHT at the draw site). One source for the smoothed torchXZ and every
// teleport snap.
fn heroLightWorld(p: *const Player) rl.Vector3 {
    return v3(p.Pos.x, 0, p.Pos.z);
}

// ---- Game state ----

pub const Game = struct {
    scene: Scene = .menu,
    rng: mathx.Rng,
    torch: tl.Torch,
    sceneMesh: scenemesh.SceneMesh,
    fog: fogmod.Fog,
    w: world.World,
    // The authored campaign: maps/*.map in lexicographic order. `map` is the CURRENT
    // area's parsed file (world, spawns, area name all come from it).
    map: mapmod.Map,
    mapPaths: [mapmod.MAX_MAPS][mapmod.PATH_CAP]u8 = undefined,
    mapPathLens: [mapmod.MAX_MAPS]usize = undefined,
    mapCount: usize = 0,
    areaIndex: usize = 0,
    lastArea: usize,
    // Town/quest trigger runtime for the CURRENT area: switch/counter values, fired flags,
    // per-NPC talk flags, and the live dialogue box. Authored logic is in map.trig; this is
    // the per-run state, reset by resetArena. See triggerTick / updateDialogue.
    trig: trigmod.Runtime = .{},
    ed: editor.Editor = .{},
    playtest: bool = false, // playing FROM the editor: all exits lead back to it

    // Start menu state + display mode.
    menuMode: MenuMode = .root,
    menuSel: i32 = 0,
    // Character stat sheet (C / Select in play): freezes the world, allocates points on sheetSel.
    sheetOpen: bool = false,
    sheetSel: i32 = 0,
    // Character-screen page + skill-tab focus. The screen is `sheetOpen`; charTab picks
    // the page; skillSel is the focused bar slot on the Skills tab.
    charTab: CharTab = .stats,
    skillSel: i32 = 0, // focused button slot (0..SKILL_SLOTS) on the Skills tab
    // Skills tab, pool model: which zone the cursor is in and the focused pool chip
    // (index into player.Skill.all). Bind = drop the focused pool skill into skillSel.
    skillZone: SkillZone = .slots,
    skillPoolSel: i32 = 0,
    // Persisted loadout: loaded once at init, applied to each fresh hero, saved on every
    // change. Survives runs and app restarts.
    loadout: playermod.SkillBar = playermod.SkillBar.default(),
    // True while a live run is paused behind the menu, so the top row resumes instead of
    // starting fresh. Cleared on death/victory.
    canResume: bool = false,
    quit: bool = false,
    displayMode: DisplayMode = .windowed,
    debugLog: bool = false, // main menu → Debug Log: per-frame light-state log (lightlog.txt)

    p: Player,
    monsters: [MAX_MONSTERS]Monster = undefined,
    monsterCount: usize = 0,
    nextID: i32 = 0,
    projs: ProjList = .{},
    lootList: std.ArrayList(LootDrop),
    gas: [MAX_GAS]GasCloud = undefined,
    gasCount: usize = 0,
    gasHurtCD: f32 = 0, // countdown to the next DoT pulse hurting the HERO (miasma)
    gasFoeCD: f32 = 0, // countdown to the next DoT pulse hurting MONSTERS (toxic flask)

    rig: CamRig,

    // Per-frame input cache.
    mouseGround: rl.Vector3 = mathx.zero3,
    kbMove: rl.Vector3 = mathx.zero3,
    hoverMonster: i32 = -1, // monster id (NOT array index): survives same-frame corpse
    // compaction in updateDeaths, so the highlight can't slip to the wrong monster.

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
    // The light's XZ this frame: the carried flame's ground point, smoothed so shadows
    // swing on a turn instead of snapping when Facing flips.
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
        g.loadout = playermod.SkillBar.load(SKILLBAR_PATH); // persisted bindings (or defaults)
        g.p.bar = g.loadout;
        g.p.retainOwned(); // never bind a persisted skill the fresh hero doesn't own yet
        g.areaIndex = 0;
        g.torch.setLightColor(g.map.light);
        g.torch.uploadFloorMats(&g.map.floorGrid, g.map.halfW, g.map.halfD);
        g.spawnPacks();
        teleportHero(&g, g.p.Pos);
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.map.name.slice()});
        return g;
    }

    // Load the idx-th campaign map; missing/corrupt falls back to the built-in empty field.
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
        // Catch edits made with the character screen still open at quit (the normal save
        // point is closeCharScreen). Only writes when actually changed, so a player who
        // never touched the loadout leaves no config file behind.
        if (!std.meta.eql(g.p.bar, g.loadout)) playermod.SkillBar.save(&g.p.bar, SKILLBAR_PATH) catch {};
        g.sceneMesh.deinit();
        g.fog.deinit();
        g.torch.deinit();
        g.lootList.deinit();
        hudx.unloadOrbRT();
        if (lightLogFile) |f| {
            f.close();
            lightLogFile = null;
        }
    }

    // startRun resets a finished/dead game back to area 0 with a fresh hero.
    pub fn startRun(g: *Game) void {
        g.playtest = false;
        g.paused = false; // a pause from the previous run must not freeze this one
        g.resetCharScreen(); // never resume into a leftover open character screen
        g.canResume = true; // a live run now exists to return to
        g.p = playermod.newPlayer(mathx.zero3);
        g.p.bar = g.loadout; // carry the persisted loadout into the new hero
        g.p.retainOwned(); // …but only for skills it already owns (just melee at run start)
        g.kills = 0;
        g.elapsed = 0;
        g.enterArea(0);
        input.swallowHeldSlots(); // a held restart-confirm (A) must not fire slot 0 on frame one
        g.scene = .playing;
    }

    // enterArea loads the given campaign map, rebuilds the world, and spawns packs.
    pub fn enterArea(g: *Game, idx: usize) void {
        g.areaIndex = if (idx > g.lastArea) g.lastArea else idx;
        g.map = g.loadMapAt(g.areaIndex);
        g.w = mapmod.toWorld(&g.map, g.areaIndex == g.lastArea);
        g.torch.setLightColor(g.map.light); // each floor gets its own night
        g.torch.uploadFloorMats(&g.map.floorGrid, g.map.halfW, g.map.halfD); // ...and its own ground materials
        g.sceneMesh.rebuild(&g.w);
        resetArena(g); // dynamic bodies, FX pools, fog, presentation timers, packs
        g.p.resetCombatState(); // no roll/stun/swing carries across the portal
        g.p.HP = g.p.MaxHP;
        g.p.Mana = g.p.MaxMana;
        teleportHero(g, g.map.spawn);
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.map.name.slice()});
    }

    // Deploy the map's authored packs (jittered around each anchor) plus the area
    // champion. Difficulty tier = campaign position.
    fn spawnPacks(g: *Game) void {
        const tier: i32 = @intCast(g.areaIndex);
        // Boss FIRST so the champion always claims a slot: an editor/hand-authored map
        // whose packs exceed MAX_MONSTERS (up to map.MAX_PACKS * map.PACK_MEMBERS_MAX
        // members) must drop rank-and-file, never the boss — else the area "clears" with no
        // champion.
        g.spawn(monster.makeBoss(tier, g.map.boss.slice(), &g.rng, g.randomOpenTileNear(g.map.bossPos, 3)));
        for (g.map.packList()) |pk| {
            var i: i32 = 0;
            while (i < pk.count) : (i += 1) {
                g.spawn(monster.makeMonster(pk.kind, tier, &g.rng, g.randomOpenTileNear(v3(pk.x, 0, pk.z), 5)));
            }
        }
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
            const p = mathx.ground(center.x + g.rng.signed() * spread, center.z + g.rng.signed() * spread);
            if (g.w.onFeature(p.x, p.z)) continue;
            if (!g.w.blocked(p, 0.8)) return p;
        }
        return center;
    }

    // inVision: within the lit disc. Beyond it is black — no targeting, no floating bars.
    pub fn inVision(g: *const Game, p: rl.Vector3) bool {
        return dist2XZ(p, g.p.Pos) <= CULL * CULL; // squared: pure threshold, called per monster/frame
    }

    // The one "can I select/name this foe" rule — alive AND inside the lit disc. Every
    // targeting scan (nearest default, hover, right-stick, plate) funnels through this so
    // the rule lives once (add an LOS/range clause here and all of them follow).
    pub fn targetable(g: *const Game, m: *const monster.Monster) bool {
        return m.alive() and g.inVision(m.Pos);
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

    /// Clear character-screen state without touching disk (used by run resets, which
    /// build a fresh hero anyway).
    pub fn resetCharScreen(g: *Game) void {
        g.sheetOpen = false;
        g.charTab = .stats;
        g.sheetSel = 0;
        g.skillSel = 0;
        g.skillZone = .slots;
        g.skillPoolSel = 0;
    }

    /// Close the character screen, persisting the loadout if the bindings changed. The
    /// single save point: bindings only change while the screen is open, so saving on
    /// close covers every edit without writing on every keystroke.
    pub fn closeCharScreen(g: *Game) void {
        if (!std.meta.eql(g.p.bar, g.loadout)) {
            g.loadout = g.p.bar;
            playermod.SkillBar.save(&g.p.bar, SKILLBAR_PATH) catch {};
        }
        input.swallowHeldSlots(); // the B that closed the sheet is dodge's button — don't roll
        g.resetCharScreen();
    }

};

// ---- Simulation ----

// updatePlaying advances the whole simulation by dt while in the playing scene.
// ── Town/quest trigger runtime ──────────────────────────────────────────────────
// A trigger = { conditions[], actions[] }: all conditions must hold, then actions run
// top→bottom (StarEdit semantics). Conversations ARE triggers — say/choice/end_* actions
// drive the dialogue box. Authored data lives in g.map.trig (a trigger.Store); the live
// values/flags live in g.trig (a trigger.Runtime), reset by resetArena.

pub const TALK_RANGE: f32 = 2.6; // how close the hero must be to talk to an NPC
const TALK_RANGE_SQ: f32 = TALK_RANGE * TALK_RANGE; // squared, for the distance tests below
const PORTAL_REACH: f32 = 2.4; // how close the hero must be to step through an area portal
const TRIGGER_CADENCE: f32 = 0.2; // seconds between passive trigger-loop evaluations
const MSG_BANNER_DUR: f32 = 2.6; // how long a `message` action holds on screen
const MAX_TRIGGER_CHAIN: u32 = 32; // run_trigger recursion guard

fn triggerTick(g: *Game, dt: f32) void {
    g.trig.elapsed += dt;
    g.trig.evalTimer -= dt;
    if (g.trig.evalTimer > 0) return;
    g.trig.evalTimer = TRIGGER_CADENCE;
    triggerEvalPass(g);
}

// Evaluate every armed trigger once, firing those whose conditions all hold. Stops early if a
// fired trigger opened a conversation (the dialogue then owns the flow until it closes).
fn triggerEvalPass(g: *Game) void {
    const store = &g.map.trig;
    var i: usize = 0;
    while (i < store.trigger_count) : (i += 1) {
        if (g.trig.dialogue.active) return;
        if (g.trig.fired[i]) continue;
        if (allCondsHold(g, &store.triggers[i])) startTrigger(g, @intCast(i));
    }
}

fn allCondsHold(g: *Game, t: *const trigmod.Trigger) bool {
    for (t.condList()) |c| {
        if (!condTrue(g, c)) return false;
    }
    return true;
}

fn condTrue(g: *Game, c: trigmod.Cond) bool {
    const r = &g.trig;
    return switch (c) {
        .always => true,
        .never => false,
        .switch_on => |id| id < r.switches.len and r.switches[id],
        .switch_off => |id| !(id < r.switches.len and r.switches[id]),
        .counter => |x| x.c < r.counters.len and x.op.holds(r.counters[x.c], x.n),
        .in_region => |id| id < g.map.region_count and g.map.regions[id].contains(g.p.Pos.x, g.p.Pos.z),
        .near_npc => |id| npcInTalkRange(g, id),
        .talked_to => |id| id < r.talked.len and r.talked[id],
        .on_talk => |id| r.interactNpc != null and r.interactNpc.? == id,
        .player_level => |x| x.op.holds(g.p.Level, x.n),
        .elapsed => |x| elapsedHolds(r.elapsed, x.op, x.secs),
    };
}

fn npcInTalkRange(g: *Game, id: u16) bool {
    if (id >= g.map.npc_count) return false;
    return dist2XZ(g.p.Pos, g.map.npcs[id].pos()) <= TALK_RANGE_SQ;
}

fn elapsedHolds(elapsed: f32, op: trigmod.Op, secs: f32) bool {
    return switch (op) {
        .at_least => elapsed >= secs,
        .at_most => elapsed <= secs,
        // "exactly" on a float is a window the width of one eval cadence.
        .exactly => @abs(elapsed - secs) <= TRIGGER_CADENCE,
    };
}

// Fire trigger tid: mark it spent (a `preserve` action re-arms it), then run its script.
fn startTrigger(g: *Game, tid: u16) void {
    g.trig.fired[tid] = true;
    executeFrom(g, tid, 0, 0);
}

// Run trigger tid's actions from index `start`, stopping when the script ends or a say/choice
// opens the dialogue box (which resumes on player input). `depth` guards run_trigger chains.
fn executeFrom(g: *Game, tid: u16, start: usize, depth: u32) void {
    if (depth > MAX_TRIGGER_CHAIN) return;
    const store = &g.map.trig;
    if (tid >= store.trigger_count) return;
    const t = &store.triggers[tid];
    var i = start;
    while (i < t.act_count) {
        const a = t.acts[i];
        switch (a) {
            .say => |x| {
                openSay(g, tid, x);
                g.trig.dialogue.cursor = i + 1;
                g.trig.dialogue.wait = .advance;
                return;
            },
            .choice => {
                gatherChoices(g, tid, i);
                return;
            },
            .end_choice, .end_dialogue => {
                closeDialogue(g);
                return;
            },
            .preserve => {
                g.trig.fired[tid] = false; // re-arm for the next pass
                i += 1;
            },
            .run_trigger => |nid| {
                executeFrom(g, nid, 0, depth + 1);
                return;
            },
            else => {
                applyImmediate(g, a);
                i += 1;
            },
        }
    }
    // Ran off the end without an explicit end_dialogue: close the box if this trigger owned it.
    if (g.trig.dialogue.active and g.trig.dialogue.trigger == tid) closeDialogue(g);
}

fn openSay(g: *Game, tid: u16, x: trigmod.Act.Say) void {
    const d = &g.trig.dialogue;
    d.active = true;
    d.trigger = tid;
    d.npc = x.npc;
    d.text.set(g.map.trig.stringText(x.text));
    d.choice_count = 0; // a fresh line clears the previous prompt's choices
    d.sel = 0;
}

// Collect the run of sibling choices starting at groupStart into the box as buttons; each
// button remembers the act index of its branch body, run when picked.
fn gatherChoices(g: *Game, tid: u16, groupStart: usize) void {
    const d = &g.trig.dialogue;
    const t = &g.map.trig.triggers[tid];
    const acts = t.actList();
    d.active = true;
    d.trigger = tid;
    d.choice_count = 0;
    d.sel = 0;
    var i = groupStart;
    while (i < t.act_count and acts[i] == .choice and d.choice_count < trigmod.MAX_ACTIVE_CHOICES) {
        var ch = trigmod.Dialogue.Choice{ .jump = i + 1 };
        ch.label.set(g.map.trig.stringText(acts[i].choice));
        d.choices[d.choice_count] = ch;
        d.choice_count += 1;
        i = trigmod.branchEnd(acts, i);
    }
    d.wait = .choose;
}

// The immediate (non-dialogue) actions — everything executeFrom doesn't handle inline.
fn applyImmediate(g: *Game, a: trigmod.Act) void {
    const r = &g.trig;
    switch (a) {
        .message => |id| g.setBanner(MSG_BANNER_DUR, "{s}", .{g.map.trig.stringText(id)}),
        .set_switch => |x| {
            if (x.s < r.switches.len) r.switches[x.s] = switch (x.mode) {
                .on => true,
                .off => false,
                .toggle => !r.switches[x.s],
            };
        },
        .set_counter => |x| {
            if (x.c < r.counters.len) r.counters[x.c] = switch (x.mode) {
                .set => x.n,
                .add => r.counters[x.c] +% x.n, // authored i32s: wrap, don't panic
                .sub => r.counters[x.c] -% x.n,
            };
        },
        .grant_skill => |sk| {
            if (g.p.learn(sk)) g.setToast("Learned {s}!", .{sk.label()});
        },
        .spawn => |x| spawnAtRegion(g, x),
        .teleport => |id| {
            if (id < g.map.region_count) teleportHero(g, g.map.regions[id].center());
        },
        .center_cam => |id| {
            if (id < g.map.region_count) g.rig.snap(g.map.regions[id].center());
        },
        .set_objective => |id| {
            r.objective.set(g.map.trig.stringText(id));
            r.hasObjective = true;
        },
        // Flow/dialogue acts are handled by executeFrom and never reach here.
        .say, .choice, .end_choice, .end_dialogue, .preserve, .run_trigger => {},
    }
}

fn spawnAtRegion(g: *Game, x: trigmod.Act.Spawn) void {
    if (x.region >= g.map.region_count) return;
    const center = g.map.regions[x.region].center();
    const tier: i32 = @intCast(g.areaIndex);
    const count = std.math.clamp(x.count, 1, 32);
    var n: i32 = 0;
    while (n < count) : (n += 1) {
        g.spawn(monster.makeMonster(x.kind, tier, &g.rng, g.randomOpenTileNear(center, 4)));
    }
}

fn closeDialogue(g: *Game) void {
    const d = &g.trig.dialogue;
    d.active = false;
    d.wait = .none;
    d.choice_count = 0;
    input.swallowHeldSlots(); // the confirm that closed the box must not fire a skill next frame
}

// While a conversation is open the world is frozen; this drives the box from player input.
fn updateDialogue(g: *Game) void {
    const d = &g.trig.dialogue;
    switch (d.wait) {
        .advance => {
            if (input.confirm(false) or input.interactPressed()) {
                executeFrom(g, d.trigger, d.cursor, 0);
            } else if (input.cancel()) {
                closeDialogue(g);
            }
        },
        .choose => {
            if (d.choice_count == 0) {
                closeDialogue(g);
                return;
            }
            if (input.navUp()) d.sel = if (d.sel == 0) d.choice_count - 1 else d.sel - 1;
            if (input.navDown()) d.sel = (d.sel + 1) % d.choice_count;
            if (input.confirm(false)) {
                const jump = d.choices[d.sel].jump;
                d.wait = .none;
                executeFrom(g, d.trigger, jump, 0);
            } else if (input.cancel()) {
                closeDialogue(g);
            }
        },
        .none => closeDialogue(g),
    }
}

// Press-to-talk: if interact is pressed near an NPC, mark it talked-to and run an immediate
// eval pass with that NPC's on_talk edge set, so its conversation trigger fires now.
fn tryInteract(g: *Game) void {
    if (!input.interactPressed()) return;
    var best: ?u16 = null;
    var bestD2: f32 = TALK_RANGE_SQ;
    for (g.map.npcList(), 0..) |npc, idx| {
        const d2 = dist2XZ(g.p.Pos, npc.pos());
        if (d2 <= bestD2) {
            bestD2 = d2;
            best = @intCast(idx);
        }
    }
    if (best) |id| {
        if (id < g.trig.talked.len) g.trig.talked[id] = true;
        g.trig.interactNpc = id;
        triggerEvalPass(g);
        g.trig.interactNpc = null;
    }
}

fn updatePlaying(g: *Game, dt_in: f32) void {
    // Clamp dt so a hitch can't tunnel entities through walls.
    var dt = dt_in;
    if (dt > 0.05) dt = 0.05;

    if (rl.isKeyPressed(.p)) g.paused = !g.paused;
    if (g.paused) return;

    // A conversation freezes the world and owns all input until it closes.
    if (g.trig.dialogue.active) {
        updateDialogue(g);
        g.rig.follow(g.p.Pos, dt);
        return;
    }

    updateAim(g);
    handleInput(g);
    handleGamepad(g);
    tryInteract(g); // press-to-talk may open a conversation (world freezes from next frame)
    updateTargeting(g); // after manual picks (hover/stick/click); fills the nearest default
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
    updateGasClouds(g, dt);
    updatePortal(g);
    updateAmbientFX(g, dt);
    g.parts.update(dt, &g.w);

    // Town/quest triggers: evaluate on a cadence AFTER movement, so region/proximity
    // conditions read the hero's settled position this frame.
    triggerTick(g, dt);

    g.rig.follow(g.p.Pos, dt);

    // Ease the light toward the hero so movement swings shadows over a few
    // frames instead of snapping.
    const lamp = heroLightWorld(&g.p);
    const lk = 1 - @exp(-dt * 9.0);
    g.torchXZ = v3(g.torchXZ.x + (lamp.x - g.torchXZ.x) * lk, 0, g.torchXZ.z + (lamp.z - g.torchXZ.z) * lk);

    // Fog of war: the torch reveals ground it sweeps (monotonic memory); upload the mask
    // before drawWorld samples it.
    g.fog.reveal(g.p.Pos, TORCH_RADIUS);
    g.fog.sync();
}

fn updateTimers(g: *Game, dt: f32) void {
    const p = &g.p;
    if (p.atkCD > 0) p.atkCD -= dt;
    if (p.castCD > 0) p.castCD -= dt;
    p.tickSkillCDs(dt);
    if (p.rollTimer > 0) p.rollTimer -= dt;
    if (p.rollCD > 0) p.rollCD -= dt;
    if (p.iframe > 0) p.iframe -= dt;
    if (p.stunTimer > 0) p.stunTimer -= dt;
    if (p.swing > 0) p.swing -= dt;
    if (p.hitFlash > 0) p.hitFlash -= dt;
    if (g.damageFlash > 0) g.damageFlash -= dt;
    if (g.shake > 0) g.shake -= dt;
    g.banner.tick(dt);
    g.toast.tick(dt);
    p.regen(dt);
}

// ---- Input ----

// Screen-bottom HUD band; clicks there don't move the hero. Owned by hudx so it tracks
// the real layout height.
const hudReserve = hudx.bottomBandHeight;

fn handleInput(g: *Game) void {
    const p = &g.p;

    // Zoom with the mouse wheel.
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) g.rig.addZoom(wheel);

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
        p.chaseMonster = -1; // manual movement cancels the chase (still faces the selection)
    } else {
        g.kbMove = mathx.zero3;
    }

    const mouse = rl.getMousePosition();
    const overHUD = mouse.y > @as(f32, @floatFromInt(rl.getScreenHeight() - hudReserve));

    // Skill bar. Mouse fires slots 0/1 (LMB carries the click-to-move fallback); keys
    // Q/E/R fire slots 2-4. Combat skills fire while HELD (auto-repeat under cooldown);
    // consumables (potions) fire on the down-EDGE so a held button doesn't chug the belt.
    if (!p.rolling()) {
        if (!overHUD) {
            if (mouseSlotFires(g, 0, .left)) fireSlot(g, 0, true);
            if (mouseSlotFires(g, 1, .right)) fireSlot(g, 1, false);
        }
        var slot: usize = 2;
        while (slot < playermod.SKILL_SLOTS) : (slot += 1) {
            if (keySlotFires(g, slot)) fireSlot(g, slot, false);
        }
    }
}

// A slot bound to a consumable fires on the button's down-EDGE (one drink per tap); any
// other skill fires while HELD (auto-repeat gated by its own cooldown). One rule, applied
// to every input source so a potion can't chug no matter which button it's on.
fn slotConsumable(g: *const Game, slot: usize) bool {
    return if (g.p.bar.slots[slot]) |s| s.consumable() else false;
}
fn mouseSlotFires(g: *const Game, slot: usize, btn: rl.MouseButton) bool {
    return if (slotConsumable(g, slot)) rl.isMouseButtonPressed(btn) else rl.isMouseButtonDown(btn);
}
fn keySlotFires(g: *const Game, slot: usize) bool {
    return if (slotConsumable(g, slot)) input.slotKeyPressed(slot) else input.slotKeyDown(slot);
}
fn padSlotFires(g: *const Game, slot: usize) bool {
    return if (slotConsumable(g, slot)) input.slotPadPressed(slot) else input.slotPadDown(slot);
}

// Fire the skill bound to `slot`. An empty slot is a no-op — except LMB, which keeps
// click-to-move so clearing slot 0 never strands the hero. `isLMB` marks the left mouse
// button, the only slot that carries move-to-ground context.
fn fireSlot(g: *Game, slot: usize, isLMB: bool) void {
    const skill = g.p.bar.slots[slot] orelse {
        if (isLMB) lmbMove(g);
        return;
    };
    switch (skill) {
        .melee => meleeAction(g, isLMB),
        .cleave => doCleave(g),
        .throwing_knife => throwKnife(g),
        .firebolt => castFirebolt(g),
        .ice_shard => castIceShard(g),
        .lightning_nova => castNova(g),
        .toxic_flask => throwFlask(g),
        .dodge => fireDodge(g),
        .health_potion => useHealthPotion(g),
        .mana_potion => useManaPotion(g),
    }
}

// Melee slot: engage the selected foe for auto-attack. On LMB it doubles as
// click-to-move (walk to the ground point when not on a foe), matching Diablo's
// left-click; on a key or pad button it only commits the chase against the selection.
fn meleeAction(g: *Game, isLMB: bool) void {
    const p = &g.p;
    if (isLMB) {
        if (lenXZ(g.kbMove) != 0) return; // WASD owns movement this frame
        const hm = g.monsterByID(g.hoverMonster);
        if (hm != null and hm.?.alive()) {
            p.targetMonster = hm.?.id; // click a foe: select AND engage (chase into melee)
            p.chaseMonster = hm.?.id;
            p.hasMoveTarget = false;
        } else {
            p.chaseMonster = -1; // click the ground: disengage and walk there (selection holds)
            p.moveTarget = g.mouseGround;
            p.hasMoveTarget = true;
        }
    } else if (p.targetMonster >= 0) {
        p.chaseMonster = p.targetMonster; // button melee: chase whoever's selected
        p.hasMoveTarget = false;
    }
}

// Left-click on an empty slot 0: pure click-to-move, so unbinding the primary slot
// can't cost you movement.
fn lmbMove(g: *Game) void {
    const p = &g.p;
    if (lenXZ(g.kbMove) != 0) return;
    p.chaseMonster = -1;
    p.moveTarget = g.mouseGround;
    p.hasMoveTarget = true;
}

// Dodge slot: roll toward movement intent, else toward the aim/cursor point. Reached only
// through the bound slot (no hardcoded shortcut) — every skill fires through the bar.
fn fireDodge(g: *Game) void {
    var dir = g.kbMove;
    if (lenXZ(dir) < 1e-3) dir = dirXZ(g.p.Pos, g.mouseGround);
    doDodge(g, dir);
}

// Where an aimed skill is thrown: the selected foe if there is one (you're already
// facing it, terrain height and all), otherwise the cursor / stick aim point. `y` is the
// hitbox-center height so a shot rains onto a raised or sunken mark. Shared by every
// aimed skill so they all lead the same target.
const Aim = struct { pt: rl.Vector3, y: f32, dir: rl.Vector3 };
fn resolveAim(g: *Game) Aim {
    const p = &g.p;
    var pt = g.mouseGround;
    var y = g.mouseGround.y + 0.9;
    if (g.monsterByID(p.targetMonster)) |m| {
        if (m.alive()) {
            pt = m.Pos;
            // Hitbox center — deliberately NOT the drawn chest (+MONSTER_TORSO_BASE): the
            // shot collides against the body volume, not the sprite.
            y = m.Pos.y + m.Height * 0.5;
        }
    }
    var dir = dirXZ(p.Pos, pt);
    if (lenXZ(dir) < 1e-4) dir = p.Facing;
    return .{ .pt = pt, .y = y, .dir = dir };
}

// A spell's live cooldown window: base recharge shortened by cast speed + CDR, exactly
// like Firebolt's castRate. One helper so every extra spell recharges on the same curve.
fn spellCooldown(g: *const Game, base: f32) f32 {
    return playermod.castCooldown(g.p.derived, base);
}

const MSG_NO_MANA = "Not enough mana";

// Try to pay a spell's mana cost. Toasts + returns false when short (caller aborts);
// deducts + returns true otherwise. THE mana gate, so the wording lives once.
fn spendMana(g: *Game, cost: f32) bool {
    if (g.p.Mana < cost) {
        g.setToast(MSG_NO_MANA, .{});
        return false;
    }
    g.p.Mana -= cost;
    return true;
}

// One crit roll against luck's global crit chance: returns the (possibly x CRIT_MULT)
// damage plus whether it critted, so damage, FX, and rumble all read the SAME roll.
fn rollCrit(g: *Game, base: f32) struct { dmg: f32, crit: bool } {
    const crit = g.rng.float() < g.p.derived.critChance;
    return .{ .dmg = if (crit) base * stats.CRIT_MULT else base, .crit = crit };
}

fn castFirebolt(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or p.castCD > 0) return;
    // Same gate shape as the other spells: silent on cooldown, MSG_NO_MANA via the one
    // shared mana gate (spendMana) — no hand-rolled toast/deduct copy.
    if (!spendMana(g, playermod.Skill.manaCost(.firebolt))) return;
    const aim = resolveAim(g);
    p.Facing = aim.dir;
    p.castCD = p.castRate; // recompute()'s cached window — the HUD veil divides by the same number
    // Firebolt is pure fire; resists (not armor) mitigate it. Crit applies here too
    // (luck's crit chance is global, as the stat sheet advertises — not melee-only).
    const roll = p.spellDmg + @as(f32, @floatFromInt(g.rng.intn(playermod.FIREBOLT_SPREAD)));
    const dmg = stats.Damage.one(.fire, rollCrit(g, roll).dmg);
    g.projs.add(projectile.newFirebolt(p.Pos, aim.dir, dmg, aim.y, distXZ(p.Pos, aim.pt)));
    g.rumble.play(rumble.cast);
}

// Ice Shard: a cold bolt scaling with spell damage; chills what it strikes (applied in
// keepProjectile on contact). Same aim/gate shape as Firebolt.
fn castIceShard(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or !p.auxReady(.ice_shard)) return;
    if (!spendMana(g, playermod.Skill.manaCost(.ice_shard))) return;
    const aim = resolveAim(g);
    p.Facing = aim.dir;
    p.startAuxCD(.ice_shard, spellCooldown(g, playermod.ICE_CD));
    const roll = playermod.ICE_DMG * p.derived.spellMult + @as(f32, @floatFromInt(g.rng.intn(playermod.ICE_SPREAD)));
    g.projs.add(projectile.newIceShard(p.Pos, aim.dir, stats.Damage.one(.cold, rollCrit(g, roll).dmg), aim.y, distXZ(p.Pos, aim.pt)));
    g.rumble.play(rumble.cast);
}

// Throwing Knife: fast, free physical dart scaling with ranged (dexterity) damage —
// the hero's only bow-less ranged attack. No mana; gated purely by its short cooldown.
fn throwKnife(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or !p.auxReady(.throwing_knife)) return;
    const aim = resolveAim(g);
    p.Facing = aim.dir;
    p.startAuxCD(.throwing_knife, spellCooldown(g, playermod.KNIFE_CD));
    const roll = g.rng.range(playermod.KNIFE_MIN, playermod.KNIFE_MAX) * p.derived.rangedMult;
    g.projs.add(projectile.newKnife(p.Pos, aim.dir, stats.Damage.phys(rollCrit(g, roll).dmg), aim.y, distXZ(p.Pos, aim.pt)));
    g.rumble.play(rumble.attack_hit);
}

// Toxic Flask: lob a vial that bursts (impactBurst) into a lingering poison cloud that
// ticks chaos damage to any foe inside. AoE + DoT; scales with spell damage.
fn throwFlask(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or !p.auxReady(.toxic_flask)) return;
    if (!spendMana(g, playermod.Skill.manaCost(.toxic_flask))) return;
    const aim = resolveAim(g);
    p.Facing = aim.dir;
    p.startAuxCD(.toxic_flask, spellCooldown(g, playermod.FLASK_CD));
    const dps = playermod.FLASK_DPS * p.derived.spellMult;
    g.projs.add(projectile.newFlask(p.Pos, aim.dir, dps, aim.y, distXZ(p.Pos, aim.pt)));
    g.rumble.play(rumble.cast);
}

// Lightning Nova: an instant burst that forks lightning through every live foe within
// NOVA_RADIUS. Self-centered AoE — no aim needed. Scales with spell damage.
fn castNova(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or !p.auxReady(.lightning_nova)) return;
    if (!spendMana(g, playermod.Skill.manaCost(.lightning_nova))) return;
    p.startAuxCD(.lightning_nova, spellCooldown(g, playermod.NOVA_CD));
    for (g.liveMonsters()) |*m| {
        if (!m.alive()) continue;
        if (distXZ(p.Pos, m.Pos) > NOVA_RADIUS + m.Radius or !sameGroundY(m.Pos.y, p.Pos.y)) continue;
        const roll = playermod.NOVA_DMG * p.derived.spellMult + @as(f32, @floatFromInt(g.rng.intn(playermod.NOVA_SPREAD)));
        const rc = rollCrit(g, roll);
        damageMonster(g, m, stats.Damage.one(.lightning, rc.dmg), rc.crit);
        // A jagged arc from the hero to each struck foe.
        g.parts.burst(&g.rng, v3(m.Pos.x, monsterChestY(m, 0.5), m.Pos.z), 8, 5.0, 0.09, 0.35, rgba(190, 215, 255, 255), 6);
    }
    // The discharge ring + a flash off the hero.
    g.parts.burst(&g.rng, v3(p.Pos.x, p.Pos.y + 0.4, p.Pos.z), 26, 7.5, 0.1, 0.5, rgba(150, 195, 255, 255), 3);
    g.parts.burst(&g.rng, v3(p.Pos.x, p.Pos.y + 1.0, p.Pos.z), 12, 3.0, 0.12, 0.6, rgba(225, 240, 255, 255), 1);
    g.shake = maxF(g.shake, 0.18);
    g.rumble.play(rumble.cast);
}

// Cleave: a sweeping physical strike that hits every live foe in a frontal arc within
// melee reach. Shares melee's swing timer but plays the wide sweep (melee thrusts);
// scales with melee damage.
fn doCleave(g: *Game) void {
    const p = &g.p;
    if (p.stunned() or p.rolling() or !p.auxReady(.cleave)) return;
    // Aim the sweep at the selected foe if there is one, else keep facing.
    if (g.monsterByID(p.targetMonster)) |m| {
        if (m.alive()) p.Facing = dirXZ(p.Pos, m.Pos);
    }
    p.startAuxCD(.cleave, playermod.CLEAVE_CD);
    p.swing = playermod.swingDur;
    p.swingKind = .sweep;
    var hit = false;
    for (g.liveMonsters()) |*m| {
        if (!m.alive()) continue;
        if (distXZ(p.Pos, m.Pos) > baseReach(p.atkRange, m.Radius) or !sameGroundY(m.Pos.y, p.Pos.y)) continue;
        const to = dirXZ(p.Pos, m.Pos);
        if (to.x * p.Facing.x + to.z * p.Facing.z < CLEAVE_ARC_DOT) continue; // behind the swing
        const rc = rollCrit(g, g.rng.range(p.MinDmg, p.MaxDmg));
        damageMonster(g, m, stats.Damage.phys(rc.dmg), rc.crit);
        hit = true;
    }
    g.rumble.play(if (hit) rumble.attack_hit else rumble.dodge);
}

// Attempt a dodge roll in dir, with shared feedback on success. Keyboard and gamepad
// share this and differ only in how they pick dir.
fn doDodge(g: *Game, dir: rl.Vector3) void {
    if (g.p.startRoll(dir)) {
        g.rumble.play(rumble.dodge);
        // The tuck kicks a fan of scuffed dust out behind the launch point.
        g.parts.burst(&g.rng, v3(g.p.Pos.x - dir.x * 0.3, g.p.Pos.y + 0.12, g.p.Pos.z - dir.z * 0.3), 7, 2.6, 0.07, 0.4, mathx.withAlpha(DUST_COLOR, 110), 5);
    }
}

// Drink a belt potion and toast it. Shared by keyboard (1/2) and gamepad (L1/R1).
fn useHealthPotion(g: *Game) void {
    if (g.p.drinkHealth()) g.setToast("Drank a Health Potion", .{});
}
fn useManaPotion(g: *Game) void {
    if (g.p.drinkMana()) g.setToast("Drank a Mana Potion", .{});
}

// ---- Gamepad ----
// Left stick moves; right stick aims/targets; the skill slots fire on X/Y + the d-pad
// (slotPad in input.zig); B dodges, L1/R1 potions, Start opens the menu (in run()).
// Scheme lives in input.zig; these aliases keep call sites terse.
const PAD = input.PAD;
const AIM_REACH = input.AIM_REACH;

// Pick a gamepad target: best-scored live monster in vision (nearest, biased toward
// aimDir when the stick is pushed). Updates hoverMonster; returns the id, or null.
fn padAcquireTarget(g: *Game, aimDir: rl.Vector3) ?i32 {
    var bestID: ?i32 = null;
    var bestScore: f32 = -std.math.floatMax(f32);
    const aiming = lenXZ(aimDir) > 0;
    for (g.liveMonsters()) |*m| {
        if (!g.targetable(m)) continue;
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
    const mv = input.stickXZ(.left_x, .left_y);
    if (lenXZ(mv) > 0) {
        g.kbMove = mv;
        p.hasMoveTarget = false;
        p.chaseMonster = -1; // manual movement cancels the chase (still faces the selection)
    }

    // Right stick: aim. Project a ground point ahead of the hero so Firebolt/dodge/hover
    // can key off g.mouseGround.
    const aimDir = input.stickXZ(.right_x, .right_y); // already a unit heading (or zero)
    const aiming = lenXZ(aimDir) > 0;
    // Aim highlight and X-attack acquire are the SAME O(monsters) scan; run it once,
    // reuse across both.
    var aimTarget: ?i32 = null;
    var scannedAim = false;
    if (aiming) {
        // Snap the projected point to terrain like the mouse path (updateAim→pickGround)
        // — y=0 would dive pad-aimed shots into the floor when firing along a rampart.
        g.mouseGround = g.w.snapY(v3(p.Pos.x + aimDir.x * AIM_REACH, 0, p.Pos.z + aimDir.z * AIM_REACH));
        aimTarget = padAcquireTarget(g, aimDir); // best-aligned foe under the stick
        scannedAim = true;
        if (aimTarget) |id| p.targetMonster = id; // sticky manual pick via the right stick
    }

    // Fire every slot whose controller button is held. A slot holding an OFFENSIVE skill
    // (melee/cleave/any aimed projectile) needs a selected target + a projected aim point
    // first, so scan once if any firing slot is offensive (mirroring the old X-acquire).
    var offensiveFiring = false;
    {
        var s: usize = 0;
        while (s < playermod.SKILL_SLOTS) : (s += 1) {
            if (input.slotPadDown(s)) {
                if (p.bar.slots[s]) |sk| {
                    if (sk.offensive()) offensiveFiring = true;
                }
            }
        }
    }
    if (offensiveFiring and !p.rolling()) {
        if (p.targetMonster < 0) {
            if ((if (scannedAim) aimTarget else padAcquireTarget(g, aimDir))) |tid| p.targetMonster = tid;
        }
        if (!aiming) g.mouseGround = g.w.snapY(v3(p.Pos.x + p.Facing.x * AIM_REACH, 0, p.Pos.z + p.Facing.z * AIM_REACH));
    }
    if (!p.rolling()) {
        var s: usize = 0;
        while (s < playermod.SKILL_SLOTS) : (s += 1) {
            if (padSlotFires(g, s)) fireSlot(g, s, false);
        }
    }
}

// updateAim refreshes the ground point under the cursor and the hovered monster.
fn updateAim(g: *Game) void {
    const ray = rl.getScreenToWorldRay(rl.getMousePosition(), g.rig.cam);
    // Terrain-aware pick: a click on a rampart top lands ON the rampart, not the floor beneath.
    if (g.w.pickGround(ray)) |pt| g.mouseGround = pt;

    g.hoverMonster = -1;
    var best2: f32 = std.math.floatMax(f32); // squared: a pure threshold pick needs no @sqrt
    for (g.liveMonsters()) |*m| {
        if (!g.targetable(m)) continue; // can't target what darkness hides
        const d2 = dist2XZ(m.Pos, g.mouseGround);
        const rr = m.Radius + 0.6;
        if (d2 < rr * rr and d2 < best2) {
            best2 = d2;
            g.hoverMonster = m.id;
        }
    }
    // Hovering a foe is a manual, STICKY target pick: it overrides the nearest-default and
    // holds after the cursor drifts back onto the ground (until the foe dies/leaves sight
    // or you pick another). It only changes the SELECTION — never engages the chase.
    if (g.hoverMonster >= 0) g.p.targetMonster = g.hoverMonster;
}

// Resolve the selected target each frame so you ALWAYS have the nearest foe selected by
// default. A valid pick (hover/right-stick sticky, or a prior default) is kept; otherwise
// fall back to the nearest foe in sight. Manual picks are applied earlier (updateAim /
// handleGamepad); this only validates and fills the default.
fn updateTargeting(g: *Game) void {
    const p = &g.p;
    if (g.monsterByID(p.targetMonster)) |m| {
        if (g.targetable(m)) return; // current selection still valid
    }
    // No valid selection: take the nearest in-sight foe. Only fill the SELECTION default —
    // never touch the chase here. A fresh default isn't an engage, and the chase may point
    // at a DIFFERENT, still-valid foe (you clicked A, then hovered B); its lifecycle is
    // owned by movement/attack (null-clear), killMonster, startRoll, and manual move.
    p.targetMonster = nearestTargetID(g) orelse -1;
}

// Nearest live, in-sight monster to the hero, or null if none. Squared distance (no sqrt).
fn nearestTargetID(g: *Game) ?i32 {
    var best2: f32 = std.math.floatMax(f32);
    var bestID: ?i32 = null;
    for (g.liveMonsters()) |*m| {
        if (!g.targetable(m)) continue;
        const d2 = dist2XZ(g.p.Pos, m.Pos);
        if (d2 < best2) {
            best2 = d2;
            bestID = m.id;
        }
    }
    return bestID;
}

// ---- Player movement + attack ----

fn updatePlayerMovement(g: *Game, dt: f32) void {
    const p = &g.p;
    // Feet on the ground every frame (covers teleports and standing on a ramp).
    p.Pos.y = g.w.groundY(p.Pos.x, p.Pos.z);

    // A dodge roll overrides all other movement and steering.
    if (p.rolling()) {
        const step = v3(p.rollDir.x * playermod.rollSpeed * dt, 0, p.rollDir.z * playermod.rollSpeed * dt);
        p.Pos = g.w.moveWithCollision(p.Pos, step, playermod.radius);
        return;
    }

    // Light-stunned: rooted until it wears off (the hero can't be heavy-stunned, so brief).
    if (p.stunned()) return;

    var dir = mathx.zero3;
    var moving = false;

    if (lenXZ(g.kbMove) > 0) {
        dir = g.kbMove; // manual strafe — facing is set from the target below, not from dir
        moving = true;
    } else if (p.chaseMonster >= 0) {
        // Engaged: close on the committed foe until inside striking range. Stop half a
        // body-radius inside reach so the hero settles into solid range, not at the edge.
        if (g.monsterByID(p.chaseMonster)) |m| {
            if (m.alive() and distXZ(p.Pos, m.Pos) > baseReach(p.atkRange, m.Radius) - m.Radius * 0.5) {
                dir = dirXZ(p.Pos, m.Pos);
                moving = true;
            }
        } else p.chaseMonster = -1;
    } else if (p.hasMoveTarget) {
        if (distXZ(p.Pos, p.moveTarget) > 0.25) {
            dir = dirXZ(p.Pos, p.moveTarget);
            moving = true;
        } else p.hasMoveTarget = false;
    }

    if (moving and lenXZ(dir) > 0) {
        const step = v3(dir.x * p.Speed * dt, 0, dir.z * p.Speed * dt);
        p.Pos = g.w.moveWithCollision(p.Pos, step, playermod.radius);
        p.walkBob += dt * 12;
        // Each stride kicks a little dust off the road.
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

    // Facing is DECOUPLED from movement: always face the selected target, so the hero
    // strafes and back-pedals while staying trained on it (full twin-stick facing). With
    // no target in sight, face the way you're moving.
    if (g.monsterByID(p.targetMonster)) |m| {
        if (m.alive()) {
            const f = dirXZ(p.Pos, m.Pos);
            if (lenXZ(f) > 0) p.Facing = f; // keep last facing if exactly coincident (dirXZ→0)
        }
    } else if (moving and lenXZ(dir) > 0) {
        p.Facing = dir;
    }
}

fn updatePlayerAttack(g: *Game) void {
    const p = &g.p;
    // Melee only swings once you've EXPLICITLY engaged (chaseMonster) — a merely
    // selected/hovered target never triggers an auto-swing. Never restart a swing already
    // in progress (e.g. a Cleave sweep fired earlier this frame) — that would overwrite its
    // swingKind with .thrust and make the drawn animation lie about the attack.
    if (p.rolling() or p.stunned() or p.chaseMonster < 0 or p.atkCD > 0 or p.swing > 0) return;
    if (g.monsterByID(p.chaseMonster)) |cm| {
        if (!cm.alive()) {
            p.chaseMonster = -1;
            return;
        }
    } else {
        p.chaseMonster = -1;
        return;
    }

    // Swing at whoever's actually in front of the blade: the nearest live foe on
    // comparable ground within a short step of reach — NOT necessarily the one you
    // engaged. If a closer foe wandered into range, the swing lands on it and re-engages
    // it, so a strike never whiffs past a nearby enemy onto a stale target.
    var target: ?*Monster = null;
    var best2: f32 = std.math.floatMax(f32);
    for (g.liveMonsters()) |*m| {
        if (!m.alive() or !sameGroundY(m.Pos.y, p.Pos.y)) continue;
        const d = distXZ(p.Pos, m.Pos);
        if (d > baseReach(p.atkRange, m.Radius) + MELEE_STEP) continue;
        const d2 = d * d;
        if (d2 < best2) {
            best2 = d2;
            target = m;
        }
    }
    const m = target orelse return; // nobody in range yet — keep closing

    if (m.id != p.chaseMonster) {
        p.chaseMonster = m.id; // re-engage the foe we're actually swinging at
        p.targetMonster = m.id;
    }

    // Close a short step if the foe sits just past reach, so the blow connects instead of
    // stopping short at the edge.
    const reach = baseReach(p.atkRange, m.Radius);
    var d = distXZ(p.Pos, m.Pos);
    if (d > reach) {
        const dir = dirXZ(p.Pos, m.Pos);
        const advance = mathx.minF(MELEE_STEP, d - reach + 0.05);
        p.Pos = g.w.moveWithCollision(p.Pos, v3(dir.x * advance, 0, dir.z * advance), playermod.radius);
        d = distXZ(p.Pos, m.Pos);
    }
    if (d > reach) return; // step blocked (wall) — try again next frame

    const rc = rollCrit(g, g.rng.range(p.MinDmg, p.MaxDmg));
    p.Facing = dirXZ(p.Pos, m.Pos);
    p.swing = playermod.swingDur;
    p.swingKind = .thrust;
    p.atkCD = p.atkRate;
    g.rumble.play(if (rc.crit) rumble.crit_hit else rumble.attack_hit);
    // Melee is untyped physical — armor (not resists) mitigates it.
    damageMonster(g, m, stats.Damage.phys(rc.dmg), rc.crit);
}

// Deal a typed hit: mitigation/HP/stun live in monster.hurt; FX (sparks, gore) and the
// kill hook live here. `crit` only tunes FX weight.
fn damageMonster(g: *Game, m: *Monster, dmg: stats.Damage, crit: bool) void {
    const landed = m.hurt(dmg);
    // Pib recoil: a knife pig that eats a heavy blow bolts, the SAME panic path as a
    // nearby death (they're scared of you). startFlee keeps the longer of any scatter.
    if (m.Kind == .fallen and m.alive() and landed >= m.MaxHP * monster.pib_recoil_frac) {
        m.startFlee(&g.rng);
    }
    // Hit sparks: pale chips off the body; crits flare bigger and golder. (No floating
    // damage numbers by owner decree — the sparks ARE the feedback.)
    const hitAt = v3(m.Pos.x, monsterChestY(m, 0.5), m.Pos.z);
    if (crit) {
        g.parts.burst(&g.rng, hitAt, 12, 5.5, 0.11, 0.5, rgba(255, 215, 90, 255), 9);
    } else {
        g.parts.burst(&g.rng, hitAt, 5, 4.0, 0.08, 0.35, rgba(255, 235, 200, 230), 9);
    }
    // The wound: heavy dark droplets of the body's ichor, falling fast.
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
    const at = v3(m.Pos.x, monsterChestY(m, 0.45), m.Pos.z);
    const n: usize = if (m.boss) 34 else 16;
    g.parts.burst(&g.rng, at, n, 6.0, 0.13, 0.7, lerpColor(m.Color, rl.Color.white, 0.25), 10);
    g.parts.burst(&g.rng, at, n / 2, 3.5, 0.16, 0.9, lerpColor(m.Color, rl.Color.black, 0.45), 12);
    // Pibs are cowards: ANY death nearby — a packmate OR any other monster you cut
    // down — sends the knife pigs scattering (they're scared of you). startFlee keeps
    // the longer scatter: a kill-chain must never SHORTEN a running panic.
    for (g.liveMonsters()) |*other| {
        if (other.Kind == .fallen and other.alive() and distXZ(other.Pos, m.Pos) < monster.flee_trigger_radius) {
            other.startFlee(&g.rng);
        }
    }
    // Zombie's last act: the corpse exhales a lingering miasma cloud — safe to kill,
    // not to stand in.
    if (m.Kind == .zombie) spawnGasCloud(g, m.Pos, m.MaxDmg * GAS_DPS_FRAC);
    if (g.p.addXP(m.XP)) onLevelUp(g);
    // rollLoot scatters in XZ with no terrain knowledge: re-seat each new drop on the
    // ground it landed on (a rampart kill may scatter off the edge).
    const firstNew = g.lootList.items.len;
    loot.rollLoot(m, &g.rng, &g.lootList);
    for (g.lootList.items[firstNew..]) |*d| d.Pos = g.w.snapY(d.Pos);
    if (m.boss) g.setToast("{s} has been slain!", .{m.name.slice()});
    // Drop the slain foe from selection AND the chase; both re-resolve next frame
    // (selection to the new nearest, the chase stays off until you re-engage).
    if (g.p.targetMonster == m.id) g.p.targetMonster = -1;
    if (g.p.chaseMonster == m.id) g.p.chaseMonster = -1;
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
    const spd = m.Speed * m.moveMult(); // chill slows every step (wander, chase, lunge, dodge)
    m.Pos = g.w.moveWithCollision(m.Pos, v3(dir.x * spd * dt, 0, dir.z * spd * dt), m.Radius);
}

fn updateMonster(g: *Game, m: *Monster, dt: f32) void {
    m.Pos.y = g.w.groundY(m.Pos.x, m.Pos.z); // feet on the ground (spawns, ramps)
    if (m.hitFlash > 0) m.hitFlash -= dt;
    if (m.atkCD > 0) m.atkCD -= dt;
    m.tickStatus(dt); // fade chill (and any future status)
    m.bob += dt * (m.Speed + 2);

    // Stunned: frozen (no steering/windup/attacks). tickStun decays the meter; applyStun
    // already cancelled any windup/swing.
    if (m.tickStun(dt)) return;

    // Strike follow-through: damage lands as the arc crosses its MIDPOINT — for
    // anim-telegraphed kinds the swing is the only warning, so the hit lands where seen.
    if (m.swing > 0) {
        const before = m.swing;
        m.swing -= dt;
        const half = m.swingTime * 0.5;
        if (before > half and m.swing <= half) resolveMonsterAttack(g, m);
        return; // committed: no steering mid-swing
    }

    // Committed strike: freeze + telegraph, then release (the player's window to roll).
    if (m.windup > 0) {
        m.windup -= dt;
        if (g.p.alive()) m.Facing = dirXZ(m.Pos, g.p.Pos);
        if (m.windup <= 0) {
            m.atkCD = m.atkRate;
            if (m.swingTime > 0) {
                m.swing = m.swingTime; // melee arc: damage lands mid-swing above
            } else {
                resolveMonsterAttack(g, m); // no follow-through: the arrow looses NOW
            }
        }
        return;
    }

    // Panic (pib whose packmate just died): run from the player — Diablo's Fallen.
    // Aggro survives, so they turn around and come back when the timer ends.
    if (m.fleeTimer > 0) {
        m.fleeTimer -= dt;
        m.lungeTimer = 0; // a panicking pib abandons any half-finished lunge
        if (g.p.alive()) {
            m.Facing = dirXZ(g.p.Pos, m.Pos); // face AWAY: they run with their backs to you
            moveMonster(g, m, m.Facing, dt * 1.15); // panic legs beat charging legs
        }
        return;
    }

    // Distance AND facing from one hero-delta: compute once (one @sqrt/monster/frame).
    const pdx = g.p.Pos.x - m.Pos.x;
    const pdz = g.p.Pos.z - m.Pos.z;
    const toPlayer = @sqrt(pdx * pdx + pdz * pdz);
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
                const ang: f32 = @floatCast(g.rng.float64() * std.math.tau);
                m.wanderDir = v3(cosf(ang), 0, sinf(ang));
            } else m.wanderDir = mathx.zero3;
        }
        if (lenXZ(m.wanderDir) > 0) {
            m.Facing = m.wanderDir;
            moveMonster(g, m, m.wanderDir, dt * 0.45);
        }
        return;
    }

    // Face the hero, reusing the delta above (guard matches dirXZ's own 1e-5).
    m.Facing = if (toPlayer < 1e-5) mathx.zero3 else v3(pdx / toPlayer, 0, pdz / toPlayer);
    if (m.Ranged) {
        // Footwork (skeleton personality): on a cooldown, juke sideways off a player
        // bolt bearing down, so the archer isn't a stationary target — gated so a line
        // of archers isn't an un-hittable wall. A live juke owns the mouse; it still
        // looses if the shot lines up mid-strafe.
        if (m.dodgeCD > 0) m.dodgeCD -= dt;
        if (m.dodgeTimer > 0) {
            m.dodgeTimer -= dt;
            moveMonster(g, m, m.dodgeDir, dt * monster.skel_dodge_speed);
            if (toPlayer <= m.atkRange and m.atkCD <= 0) m.windup = m.windupTime;
            return;
        }
        if (m.dodgeCD <= 0) {
            if (dodgeFromBolt(g, m)) |ddir| {
                m.dodgeDir = ddir;
                m.dodgeTimer = monster.skel_dodge_time;
                m.dodgeCD = monster.skel_dodge_cd_min + g.rng.float() * monster.skel_dodge_cd_rand;
                moveMonster(g, m, ddir, dt * monster.skel_dodge_speed);
                return;
            }
        }
        // Kite: hold at range, back off if the player gets close, then shoot.
        if (toPlayer > m.atkRange * 0.85) {
            moveMonster(g, m, m.Facing, dt); // == dirXZ(m.Pos, g.p.Pos), already set above
        } else if (toPlayer < m.atkRange * 0.35) {
            moveMonster(g, m, v3(-m.Facing.x, 0, -m.Facing.z), dt * 0.7); // away from the hero
        } else if (m.atkCD > 0.25) {
            // Between shots: sidestep an arc, id parity picking the direction so a pack
            // splits both ways. Facing stays on the player so the bow keeps pointing.
            const tang = mathx.perpXZ(m.Facing);
            const sdir = if (@rem(m.id, 2) == 0) tang else v3(-tang.x, 0, -tang.z);
            moveMonster(g, m, sdir, dt * 0.45);
        }
        if (toPlayer <= m.atkRange and m.atkCD <= 0) m.windup = m.windupTime;
        return;
    }

    // Melee: close the gap, then commit to a telegraphed swing — but never wind up at
    // someone a cliff above/below; keep pressing (funnels the pack to the ramp).
    const inMelee = toPlayer <= baseReach(m.atkRange, playermod.radius) and sameGroundY(m.Pos.y, g.p.Pos.y);
    if (inMelee and m.atkCD <= 0) {
        m.lungeTimer = 0; // a lunge that connects ends here — no phantom dash after the swing
        m.windup = m.windupTime;
        return;
    }
    // Pib lunge (fallen personality): a committed dash on a cadence that closes the
    // gap in a burst — the knife pigs dart in rather than trudge. A live lunge locks a
    // boosted charge at the hero (Facing is already the hero direction).
    if (m.Kind == .fallen) {
        if (m.lungeCD > 0) m.lungeCD -= dt;
        if (m.lungeTimer > 0) {
            m.lungeTimer -= dt;
            // Keep dashing until the lunge reaches melee; then drop it and fall through
            // so the attack/wait logic runs instead of overshooting past the hero.
            if (!inMelee) {
                moveMonster(g, m, m.Facing, dt * monster.pib_lunge_speed);
                return;
            }
            m.lungeTimer = 0;
        }
        if (m.lungeCD <= 0 and !inMelee and toPlayer < monster.pib_lunge_range) {
            m.lungeTimer = monster.pib_lunge_time;
            m.lungeCD = monster.pib_lunge_cd_min + g.rng.float() * monster.pib_lunge_cd_rand;
            moveMonster(g, m, m.Facing, dt * monster.pib_lunge_speed);
            return;
        }
    }
    if (!inMelee) moveMonster(g, m, m.Facing, dt); // == dirXZ(m.Pos, g.p.Pos), already set above
}

// A skeleton's read on the nearest player bolt bearing down on it: if one is closing
// (within sense range AND heading roughly at the archer), return a sideways strafe
// (perpendicular to the bolt, toward the side the archer already sits on so the juke
// widens the miss); null if nothing warrants a dodge. Scans the small projectile pool.
fn dodgeFromBolt(g: *Game, m: *const Monster) ?rl.Vector3 {
    var best: f32 = monster.skel_dodge_sense;
    var out: ?rl.Vector3 = null;
    for (g.projs.items()) |*pr| {
        if (!pr.FromPlayer) continue;
        const rx = m.Pos.x - pr.Pos.x;
        const rz = m.Pos.z - pr.Pos.z;
        const d = @sqrt(rx * rx + rz * rz);
        if (d >= best or d < 1e-4) continue;
        const vlen = lenXZ(pr.Vel);
        if (vlen < 1e-4) continue;
        const vx = pr.Vel.x / vlen;
        const vz = pr.Vel.z / vlen;
        // Bolt heading vs the direction to the archer: below this it's aimed elsewhere
        // or already sailing past, not worth spending a dodge on.
        if ((vx * rx + vz * rz) / d < monster.skel_dodge_align) continue;
        // Perp of the bolt heading is perpXZ(v) = (v.z, 0, -v.x); pick the side the
        // archer is already offset toward so the strafe increases the miss distance.
        const px = vz;
        const pz = -vx;
        const side: f32 = if (rx * px + rz * pz >= 0) 1 else -1;
        out = v3(px * side, 0, pz * side);
        best = d;
    }
    return out;
}

fn resolveMonsterAttack(g: *Game, m: *Monster) void {
    if (!g.p.alive()) return;
    // Every current foe deals untyped physical; a typed foe would build a different packet.
    const dmg = stats.Damage.phys(g.rng.range(m.MinDmg, m.MaxDmg));
    if (m.Ranged) {
        // The arrow looses from the drawn bow (not the body center), so nocked and
        // flying shaft are one motion. It angles to the player's true elevation — a
        // rampart is cover from the cliff side, not from a clean line.
        const bowHead = skelBow(m).head;
        // spawn() lifts by arrowMuzzleDY (ground-point contract) — pre-subtract so the
        // shaft materializes ON the drawn bow, not a muzzle-height above it.
        const from = v3(bowHead.x, m.Pos.y + bowHead.y - projectile.arrowMuzzleDY, bowHead.z);
        g.projs.add(projectile.newArrow(from, dirXZ(from, g.p.Pos), dmg, g.p.Pos.y + playermod.hitY, distXZ(from, g.p.Pos)));
        // String-snap: a flick of pale sparks off the arrowhead at release.
        g.parts.burst(&g.rng, v3(bowHead.x, m.Pos.y + bowHead.y, bowHead.z), 5, 2.6, 0.05, 0.3, rgba(255, 240, 210, 230), 4);
        return;
    }
    // The zombie's slam hits the GROUND regardless: a dust kick punctuates it (no ring).
    if (m.Kind == .zombie) {
        const f = mathx.orFacing(m.Facing, 0, 1);
        const at = v3(m.Pos.x + f.x * (m.Radius + ZOMBIE_SLAM_FWD), m.Pos.y + 0.15, m.Pos.z + f.z * (m.Radius + ZOMBIE_SLAM_FWD));
        g.parts.burst(&g.rng, at, 8, 3.2, 0.09, 0.4, mathx.withAlpha(DUST_COLOR, 150), 6);
        g.shake = maxF(g.shake, 0.12); // the ground answers even a miss
    }
    // Same reach the drawn telegraph ring uses (drawMonstersFX), so outside the ring is
    // safe. Melee can't land across a cliff: reach requires comparable ground.
    if (distXZ(m.Pos, g.p.Pos) <= meleeReach(m.atkRange, playermod.radius) and sameGroundY(m.Pos.y, g.p.Pos.y)) hitPlayer(g, dmg);
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
            // Squared pre-check: most pairs don't overlap; skip the @sqrt for them.
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

// Shared tail of every damage source: on a lethal blow, fire the death rumble and
// switch to the death screen. One spot for a future death hook.
// Leave gameplay for a terminal screen (death/victory). Presentation timers only decay
// in .playing, so a lethal/last-frame hit's flash/shake would judder the target screen
// forever unless cleared here; the run is over, so nothing is resumable.
fn endRun(g: *Game, to: Scene) void {
    g.damageFlash = 0;
    g.shake = 0;
    g.scene = to;
    g.canResume = false;
}

fn onPlayerDeath(g: *Game) void {
    if (g.p.alive()) return;
    g.rumble.play(rumble.death);
    endRun(g, .dead);
}

// Every hero damage source funnels here: i-frame gate, mitigation, and the death check
// live ONCE. Returns what landed (0 = negated/resisted → the caller skips its FX). A new
// damage source (trap, DoT) only has to pick its flash/rumble/burst dressing.
fn hurtHero(g: *Game, dmg: stats.Damage) f32 {
    // I-frames from a dodge roll negate the blow entirely.
    if (g.p.invulnerable()) return 0;
    // takeDamage applies armor+resists and returns what landed (a big hit light-stuns).
    const landed = g.p.takeDamage(dmg);
    if (landed > 0) onPlayerDeath(g);
    return landed;
}

fn hitPlayer(g: *Game, dmg: stats.Damage) void {
    if (hurtHero(g, dmg) <= 0) return;
    g.damageFlash = DAMAGE_FLASH_DUR;
    g.shake = maxF(g.shake, 0.25);
    g.rumble.play(rumble.hurt);
    g.parts.burst(&g.rng, v3(g.p.Pos.x, g.p.Pos.y + 1.35, g.p.Pos.z), 8, 4.5, 0.1, 0.45, rgba(220, 40, 40, 255), 9);
}

// Retain-in-place: keep items where keepFn returns true, compacting survivors to the
// front. keepFn mutates its item (aliases the live slot) and may run side effects.
// Returns the new length; shared by the per-frame entity sweeps.
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
    // Trail: the firebolt sheds fire sparks; the ice shard a cold mist. Knife/flask/arrow
    // fly clean so they stay legible in the dark.
    switch (pr.Kind) {
        .firebolt => g.parts.spawn(.{
            .Pos = v3(pr.Pos.x + (g.rng.float() - 0.5) * 0.25, pr.Pos.y + (g.rng.float() - 0.5) * 0.25, pr.Pos.z + (g.rng.float() - 0.5) * 0.25),
            .Vel = v3(-pr.Vel.x * 0.06, 0.6 + g.rng.float(), -pr.Vel.z * 0.06),
            .Life = 0.28 + g.rng.float() * 0.22,
            .maxLife = 0.5,
            .Size = 0.09,
            .Color = if (g.rng.float() < 0.6) projectile.fireboltColor else rgba(255, 220, 120, 255),
            .grav = -1.5,
            .drag = 1.5,
        }),
        .ice_shard => g.parts.spawn(.{
            .Pos = v3(pr.Pos.x + (g.rng.float() - 0.5) * 0.2, pr.Pos.y + (g.rng.float() - 0.5) * 0.2, pr.Pos.z + (g.rng.float() - 0.5) * 0.2),
            .Vel = v3(-pr.Vel.x * 0.04, -0.3 - g.rng.float() * 0.4, -pr.Vel.z * 0.04),
            .Life = 0.22 + g.rng.float() * 0.18,
            .maxLife = 0.4,
            .Size = 0.07,
            .Color = if (g.rng.float() < 0.5) projectile.iceShardColor else rgba(225, 245, 255, 255),
            .grav = 0.6, // frost motes sink
            .drag = 2.0,
        }),
        else => {},
    }
    if (pr.Life <= 0 or g.w.rayHitsObstacle(pr.Pos, pr.Radius)) {
        impactBurst(g, pr);
        return false;
    }
    // Hits require passing through the body's height band, so a bolt raining off a
    // rampart clears the heads between it and its mark.
    if (pr.FromPlayer) {
        for (g.liveMonsters()) |*m| {
            if (m.alive() and dist2XZ(m.Pos, pr.Pos) < (m.Radius + pr.Radius) * (m.Radius + pr.Radius) and @abs(pr.Pos.y - (m.Pos.y + m.Height * MONSTER_HIT_FRAC)) < m.Height * MONSTER_HIT_FRAC + MONSTER_HIT_PAD) {
                // A flask carries no direct hit — it bursts into a cloud (impactBurst).
                if (pr.Kind != .flask) {
                    damageMonster(g, m, pr.Damage, false);
                    if (pr.Kind == .ice_shard) m.applyChill(playermod.CHILL_DUR, playermod.CHILL_FACTOR);
                }
                impactBurst(g, pr);
                return false;
            }
        }
    } else if (g.p.alive() and dist2XZ(g.p.Pos, pr.Pos) < (playermod.radius + pr.Radius) * (playermod.radius + pr.Radius) and @abs(pr.Pos.y - (g.p.Pos.y + playermod.hitY)) < playermod.hitHalf) {
        hitPlayer(g, pr.Damage);
        impactBurst(g, pr);
        return false;
    }
    return true;
}

// A projectile ends its flight, its burst keyed to what it is: fire detonation, frost
// shatter, metallic spark, or a flask cracking open into a poison cloud; the monster's
// arrow just splinters faintly.
fn impactBurst(g: *Game, pr: *const Projectile) void {
    switch (pr.Kind) {
        .firebolt => {
            g.parts.burst(&g.rng, pr.Pos, 16, 6.5, 0.13, 0.45, rgba(255, 170, 60, 255), 8);
            g.parts.burst(&g.rng, pr.Pos, 8, 3.0, 0.1, 0.6, rgba(255, 235, 160, 255), 4);
        },
        .ice_shard => {
            g.parts.burst(&g.rng, pr.Pos, 14, 5.5, 0.1, 0.4, projectile.iceShardColor, 10);
            g.parts.burst(&g.rng, pr.Pos, 6, 2.5, 0.08, 0.5, rgba(230, 248, 255, 255), 12);
        },
        .knife => g.parts.burst(&g.rng, pr.Pos, 6, 4.0, 0.06, 0.3, rgba(210, 216, 226, 235), 14),
        .flask => {
            // Crack open into a lingering poison cloud that ticks chaos damage to foes.
            spawnPoisonCloud(g, g.w.snapY(pr.Pos), pr.Payload);
            g.parts.burst(&g.rng, pr.Pos, 12, 4.5, 0.12, 0.5, projectile.toxicColor, 6);
        },
        .arrow => g.parts.burst(&g.rng, pr.Pos, 5, 3.0, 0.07, 0.3, rgba(210, 205, 180, 200), 10),
    }
}
fn updateProjectiles(g: *Game, dt: f32) void {
    g.projs.count = retain(Projectile, g.projs.items(), SweepCtx{ .g = g, .dt = dt }, keepProjectile);
}

// Loot: bob in place; collected (and dropped) when the player walks over it.
fn keepLoot(c: SweepCtx, d: *LootDrop) bool {
    d.bob += c.dt * 3;
    // Same-level pickup only: a rampart edge must not hoover drops on the floor below.
    // A hair more vertical slack than combat's SAME_GROUND_DY so a drop nudged onto a
    // low step is still reachable, but not a full storey down.
    if (distXZ(d.Pos, c.g.p.Pos) < playermod.radius + 1.3 and @abs(d.Pos.y - c.g.p.Pos.y) < SAME_GROUND_DY + 0.2) {
        // Only remove if actually picked up; a full belt leaves the potion on the ground.
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

// A zombie's death miasma: hurts the HERO who lingers in it.
fn spawnGasCloud(g: *Game, pos: rl.Vector3, dps: f32) void {
    addGasCloud(g, pos, dps, false);
}
// The hero's Toxic Flask cloud: hurts MONSTERS caught in it.
fn spawnPoisonCloud(g: *Game, pos: rl.Vector3, dps: f32) void {
    addGasCloud(g, pos, dps, true);
}
fn addGasCloud(g: *Game, pos: rl.Vector3, dps: f32, fromPlayer: bool) void {
    if (g.gasCount >= g.gas.len) return;
    g.gas[g.gasCount] = .{ .Pos = pos, .life = GAS_LIFE, .dps = dps, .seed = g.rng.angle(), .fromPlayer = fromPlayer };
    g.gasCount += 1;
    // The rot boiling OUT — buoyant, sickly.
    g.parts.burst(&g.rng, v3(pos.x, pos.y + 0.7, pos.z), 18, 2.4, 0.15, 1.2, GAS_BURST_COLOR, -2);
}

// Advance one miasma cloud: age it out, exhale slow wisps while it lives. Wisps gate
// at the torch radius (nothing dynamic glows beyond the light).
fn keepGas(c: SweepCtx, gc: *GasCloud) bool {
    const g = c.g;
    gc.life -= c.dt;
    if (gc.life <= 0) return false;
    if (distXZ(gc.Pos, g.p.Pos) <= TORCH_RADIUS and g.rng.float() < c.dt * 14) {
        const ang = g.rng.angle();
        const r = g.rng.float() * GAS_RADIUS * 0.85;
        g.parts.spawn(.{
            .Pos = v3(gc.Pos.x + cosf(ang) * r, gc.Pos.y + 0.15 + g.rng.float() * 0.5, gc.Pos.z + sinf(ang) * r),
            .Vel = v3((g.rng.float() - 0.5) * 0.3, 0.25 + g.rng.float() * 0.3, (g.rng.float() - 0.5) * 0.3),
            .Life = 1.1 + g.rng.float() * 0.6,
            .maxLife = 1.7,
            .Size = 0.12 + g.rng.float() * 0.09,
            // Bright enough that the pool's alpha blend only lifts the ground, never dims it.
            .Color = GAS_WISP_COLOR,
            .grav = -0.35, // rot gas rises
            .drag = 1.2,
        });
    }
    return true;
}

// Summed DoT of every gas cloud of the given source overlapping `pos` (same-ground only).
// One loop for the foe-vs-hero sinks so their radius/ground test can't drift apart.
fn gasDpsAt(g: *const Game, pos: rl.Vector3, fromPlayer: bool) f32 {
    var dps: f32 = 0;
    for (g.gas[0..g.gasCount]) |*gc| {
        if (gc.fromPlayer == fromPlayer and dist2XZ(pos, gc.Pos) <= GAS_RADIUS * GAS_RADIUS and sameGroundY(pos.y, gc.Pos.y)) dps += gc.dps;
    }
    return dps;
}

fn updateGasClouds(g: *Game, dt: f32) void {
    g.gasCount = retain(GasCloud, g.gas[0..g.gasCount], SweepCtx{ .g = g, .dt = dt }, keepGas);
    if (g.gasHurtCD > 0) g.gasHurtCD -= dt;
    if (g.gasFoeCD > 0) g.gasFoeCD -= dt;

    // Toxic-flask clouds (fromPlayer) choke MONSTERS standing in them. Independent of the
    // hero's state — a poison cloud keeps working even while you roll or lie dead.
    const foeTick = g.gasFoeCD <= 0;
    if (foeTick) g.gasFoeCD = GAS_TICK;
    // Damage only lands on the tick, and gasDpsAt has no side effects, so the per-monster
    // cloud scan is pure waste on the ~26/27 frames between ticks — gate it on the tick.
    if (foeTick) {
        for (g.liveMonsters()) |*m| {
            if (!m.alive()) continue;
            const dps = gasDpsAt(g, m.Pos, true);
            if (dps > 0) damageMonster(g, m, stats.Damage.one(.chaos, dps * GAS_TICK), false);
        }
    }

    if (!g.p.alive() or g.p.invulnerable()) return; // a roll carries you clean through the fumes
    // Zombie miasma (not fromPlayer) hurts the hero. Overlapping clouds stack: standing in
    // a zombie pile's remains is its own mistake. Same gate: only scan when the pulse is ready.
    if (g.gasHurtCD <= 0) {
        const dps = gasDpsAt(g, g.p.Pos, false);
        if (dps > 0) {
            g.gasHurtCD = GAS_TICK;
            gasHurtPlayer(g, dps * GAS_TICK);
        }
    }
}

// Miasma damage arrives as discrete choking pulses, not a silent drain, so each tick
// is FELT (flash + rumble + a cough of green).
fn gasHurtPlayer(g: *Game, dmg: f32) void {
    // Miasma is poison — classed as chaos, so chaos resist (not armor) blunts it.
    if (hurtHero(g, stats.Damage.one(.chaos, dmg)) <= 0) return;
    g.damageFlash = maxF(g.damageFlash, DAMAGE_FLASH_DUR * 0.5);
    g.rumble.play(rumble.gas_tick);
    g.parts.burst(&g.rng, v3(g.p.Pos.x, g.p.Pos.y + 1.3, g.p.Pos.z), 4, 1.8, 0.08, 0.5, GAS_COUGH_COLOR, -1);
}

// Ambient particles: violet motes up the open portal, gold glints over piles, warm
// torchlight dust, and dark embers off the champion.
fn updateAmbientFX(g: *Game, dt: f32) void {
    g.portalPuff -= dt;
    if (g.portalPuff <= 0) {
        g.portalPuff = 0.05;
        // Torchlight dust: dim, slow motes drifting the lit disc make the AIR visible.
        if (g.rng.float() < 0.55) {
            const dang = g.rng.angle();
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
        // Warm sparks drift up around the light-bearer now and then (the torch prop
        // is gone; the air near the hero still lives).
        if (g.rng.float() < 0.12 and g.p.alive()) {
            const sang = g.rng.angle();
            g.parts.spawn(.{
                .Pos = v3(g.p.Pos.x + cosf(sang) * 0.7, g.p.Pos.y + 0.4 + g.rng.float() * 1.4, g.p.Pos.z + sinf(sang) * 0.7),
                .Vel = v3((g.rng.float() - 0.5) * 0.5, 0.7 + g.rng.float() * 0.7, (g.rng.float() - 0.5) * 0.5),
                .Life = 0.45 + g.rng.float() * 0.35,
                .maxLife = 0.8,
                .Size = 0.035 + g.rng.float() * 0.02,
                .Color = if (g.rng.float() < 0.6) rgba(255, 180, 70, 200) else rgba(255, 120, 40, 180),
                .grav = -0.7, // buoyant: hot air carries it up before it gutters
                .drag = 1.4,
            });
        }
        // The champion smolders: dark-red embers curl off its shoulders in your light —
        // you feel the boss before you read the name.
        for (g.liveMonsters()) |*m| {
            if (!m.boss or !m.alive()) continue;
            if (distXZ(m.Pos, g.p.Pos) > TORCH_RADIUS or g.rng.float() > 0.55) continue;
            g.parts.spawn(.{
                .Pos = v3(m.Pos.x + (g.rng.float() - 0.5) * m.Radius * 1.7, monsterChestY(m, 0.5 + g.rng.float() * 0.35), m.Pos.z + (g.rng.float() - 0.5) * m.Radius * 1.7),
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
            const ang = g.rng.angle();
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
    // Lingering gas or a last arrow can kill the same frame the hero reaches the ring —
    // death must win over the portal. Same-ground gate like melee/loot: a hero on a
    // ledge above the ring must not fall through the cliff into the vortex.
    if (g.w.PortalOpen and g.p.alive() and distXZ(g.p.Pos, g.w.PortalPos) < PORTAL_REACH and
        sameGroundY(g.p.Pos.y, g.w.groundY(g.w.PortalPos.x, g.w.PortalPos.z)))
    {
        if (g.playtest) {
            endPlaytest(g);
            g.ed.status("portal reached - playtest complete", .{});
        } else if (g.w.IsLast) {
            endRun(g, .victory);
        } else {
            g.enterArea(g.areaIndex + 1);
        }
    }
}

// Clear all per-arena dynamic state (bodies, FX pools, fog mask, presentation timers)
// then repopulate packs. Shared by enterArea and startPlaytest so a killing blow's
// flash/shake or a stale toast can't bleed across the transition.
fn resetArena(g: *Game) void {
    g.monsterCount = 0;
    g.projs.count = 0;
    g.lootList.clearRetainingCapacity();
    g.gasCount = 0; // miasma stays with its corpse — it never rides the portal
    g.gasHurtCD = 0; // don't carry a mid-countdown tick into the new area
    g.gasFoeCD = 0;
    g.parts.clear(); // stray sparks must not carry across the portal
    g.damageFlash = 0; // timers only decay in .playing, so a killing blow's
    g.shake = 0; // flash/shake would otherwise replay over the fresh area
    g.fog.reset(g.w.HalfW, g.w.HalfD); // fresh layout: forget the old exploration
    g.fog.sync(); // upload now: a restart from dead/victory draws a frame without
    // updatePlaying, else it'd show the new area against the old fog mask.
    g.trig.reset(); // fresh area: clear switch/counter values, fired flags, any open dialogue
    g.spawnPacks();
    g.setToast("", .{});
}

// Teleport the hero: set Pos AND snap the camera and smoothed light anchor. All three
// move together — a bare Pos change leaves the shadow rig lerping across the map.
fn teleportHero(g: *Game, pos: rl.Vector3) void {
    g.p.Pos = pos;
    g.rig.snap(pos);
    g.torchXZ = heroLightWorld(&g.p);
}

// Playtest the CURRENT in-memory map from the editor: real spawns/fog/HUD. Every exit
// leads back to the editor with the map untouched — no disk round-trip.
pub fn startPlaytest(g: *Game) void {
    g.playtest = true;
    g.paused = false;
    g.canResume = false; // a playtest is not a resumable adventure
    g.resetCharScreen();
    g.p = playermod.newPlayer(g.map.spawn);
    g.p.bar = g.loadout;
    g.p.retainOwned(); // playtest starts like a fresh run: only owned skills stay bound
    g.w.PortalOpen = false;
    resetArena(g);
    teleportHero(g, g.p.Pos);
    g.setBanner(AREA_BANNER_DUR, "Playtest: {s}", .{g.map.name.slice()});
    g.scene = .playing;
}

// Ctrl+F5 (crawler): playtest starting from the editor's cursor, not the spawn.
pub fn startPlaytestAt(g: *Game, at: rl.Vector3) void {
    startPlaytest(g);
    teleportHero(g, g.w.snapY(at));
}

fn endPlaytest(g: *Game) void {
    g.playtest = false;
    editor.apply(g); // clean world, no monsters, fog fully revealed
    g.scene = .editor;
}

// ---- Rendering (frozen torchlight + baked scene mesh) ----

// The hero's walk bob, shared by the body parts so limbs and torso can't drift.
// Mirrors monsterBob for the foes.
fn heroBob(p: *const Player) f32 {
    return BOB_AMP * sinf(p.walkBob);
}

// The hero's blade arm through the melee thrust, in one place: body pose and FX steel
// read the same grip so glove and blade can't separate (same contract as pibGrip).
//
// Melee strikes ONE foe, so it reads as a fencing lunge, not a sweep: the point snaps
// out of the guard (dead stop at full extension), plants for a beat, then eases back.
// At full extension the tip sits exactly at atkRange — the steel never lies about reach.
const HeroThrust = struct { ext: f32, sh: rl.Vector3, hand: rl.Vector3, tip: rl.Vector3 };

fn heroThrustAt(p: *const Player, a: f32) HeroThrust {
    var ext: f32 = 0;
    if (a < 0.32) {
        const u = clampF(a, 0, 0.32) / 0.32;
        ext = 1 - (1 - u) * (1 - u);
    } else if (a < 0.58) {
        ext = 1;
    } else {
        const u = clampF((a - 0.58) / 0.42, 0, 1);
        ext = 1 - u * u * (3 - 2 * u);
    }
    const base = p.Pos;
    const bob = heroBob(p);
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);
    const shDrive = 0.03 + 0.1 * ext; // shoulder rides the lunge lean
    const sh = v3(base.x + right.x * 0.3 + f.x * shDrive, 1.32 + bob, base.z + right.z * 0.3 + f.z * shDrive);
    // Hip-high guard grip rolls inward and up as it drives to a chest-high point.
    const lat = 0.34 - 0.22 * ext;
    const fwd = 0.16 + 0.5 * ext;
    const handY = 0.98 + bob + 0.24 * ext;
    const hand = v3(base.x + right.x * lat + f.x * fwd, handY, base.z + right.z * lat + f.z * fwd);
    const tipDist = 0.55 + (p.atkRange / HERO_SCALE - 0.55) * ext;
    const tip = v3(base.x + f.x * tipDist + right.x * lat * 0.3, handY + 0.12 * (1 - ext), base.z + f.z * tipDist + right.z * lat * 0.3);
    return .{ .ext = ext, .sh = sh, .hand = hand, .tip = tip };
}

fn heroThrust(p: *const Player) HeroThrust {
    const live = p.swing > 0 and p.swingKind == .thrust;
    return heroThrustAt(p, if (live) 1 - p.swing / playermod.swingDur else 0);
}

// The hero: a cloaked, hooded ranger; plain tint (torchlight shades it). Drawn
// HERO_SCALE bigger about the feet (depth pass too, so the shadow grows with him).
fn drawHeroBody(p: *const Player) void {
    // Clean-stack pre-flush like drawMonsterBody: an overflow inside the scale-about-feet
    // transform would light the flushed scene through that scale, and the hero is the
    // BIGGEST body (~6.3k verts). (See the matModel note on drawMonsterBody.)
    rl.gl.rlDrawRenderBatchActive();
    const base = p.Pos;
    beginHeroScale(base);
    defer rl.gl.rlPopMatrix();
    const bob = heroBob(p);
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

    const thr = heroThrust(p);
    const legCol = rgba(40, 40, 46, 255);
    for ([_]f32{ -1, 1 }) |s| {
        // Thrust lunge: blade-side foot drives ahead, off foot braces behind.
        const lungeAmt: f32 = if (s > 0) 0.34 else -0.26;
        const lunge = thr.ext * lungeAmt;
        const lx = base.x + right.x * 0.18 * s + f.x * lunge;
        const lz = base.z + right.z * 0.18 * s + f.z * lunge;
        rl.drawCapsule(v3(lx, 0.08, lz), v3(lx - f.x * lunge * 0.55, 0.55 + bob - 0.06 * thr.ext, lz - f.z * lunge * 0.55), 0.16, 8, 6, legCol);
    }

    if (p.hitFlash > 0) cloak = lerpColor(cloak, rl.Color.white, 0.6);
    // The cloak flares from the belt into an A-line skirt — the "cloaked wanderer" shape
    // from the iso camera (feet peek below the hem).
    const ld = 0.12 * thr.ext; // lunge lean: hood and shoulders drive over the front foot
    rl.drawCylinderEx(v3(base.x, 0.6 + bob, base.z), v3(base.x, 0.16 + bob * 0.5, base.z), 0.33, 0.54, 10, lerpColor(cloak, rl.Color.black, 0.22));
    rl.drawCapsule(v3(base.x, 0.5 + bob, base.z), v3(base.x + f.x * ld, 1.42 + bob, base.z + f.z * ld), 0.42, 12, 8, cloak);
    rl.drawCapsule(v3(base.x - f.x * 0.22, 0.55 + bob, base.z - f.z * 0.22), v3(base.x - f.x * 0.12, 1.25 + bob, base.z - f.z * 0.12), 0.3, 10, 6, lerpColor(cloak, rl.Color.black, 0.25));
    // Leather belt with a brass buckle — a warm accent splitting the silhouette into torso-over-skirt.
    rl.drawCylinderEx(v3(base.x, 0.88 + bob, base.z), v3(base.x, 0.98 + bob, base.z), 0.435, 0.42, 10, rgba(74, 50, 30, 255));
    sphere(v3(base.x + f.x * 0.42, 0.93 + bob, base.z + f.z * 0.42), 0.06, theme.trimColor);

    // Sleeved arms hang relaxed at his sides, gloved hands at the hem — no tool
    // grips, so the silhouette reads true for any loadout. The melee thrust is the one
    // exception: the blade arm snaps into a fencing extension (grip shared with the FX
    // steel via heroThrust), the off arm sweeps back and up for counterbalance.
    const sleeve = lerpColor(hood, rl.Color.black, 0.1);
    const glove = rgba(74, 50, 30, 255);
    if (thr.ext > 0) {
        rl.drawCapsule(thr.sh, thr.hand, 0.1, 6, 4, sleeve);
        sphere(thr.hand, 0.095, glove);
        const e = thr.ext;
        const bsh = v3(base.x - right.x * 0.3 + f.x * 0.03, 1.32 + bob, base.z - right.z * 0.3 + f.z * 0.03);
        const bhand = v3(base.x - right.x * (0.42 + 0.08 * e) + f.x * (0.12 - 0.5 * e), 0.88 + bob + 0.3 * e, base.z - right.z * (0.42 + 0.08 * e) + f.z * (0.12 - 0.5 * e));
        rl.drawCapsule(bsh, bhand, 0.1, 6, 4, sleeve);
        sphere(bhand, 0.095, glove);
    } else {
        for ([_]f32{ -1, 1 }) |s| {
            const sh = v3(base.x + right.x * 0.3 * s + f.x * 0.03, 1.32 + bob, base.z + right.z * 0.3 * s + f.z * 0.03);
            const hand = v3(base.x + right.x * 0.42 * s + f.x * 0.12, 0.88 + bob, base.z + right.z * 0.42 * s + f.z * 0.12);
            rl.drawCapsule(sh, hand, 0.1, 6, 4, sleeve);
            sphere(hand, 0.095, glove);
        }
    }

    sphere(v3(base.x + f.x * ld, 1.72 + bob, base.z + f.z * ld), 0.34, hood);
    sphere(v3(base.x + f.x * (0.22 + ld), 1.70 + bob, base.z + f.z * (0.22 + ld)), 0.2, lerpColor(skin, rl.Color.black, 0.35));
    rl.drawCylinderEx(v3(base.x - f.x * (0.1 - ld), 1.9 + bob, base.z - f.z * (0.1 - ld)), v3(base.x - f.x * (0.3 - ld), 2.18 + bob, base.z - f.z * (0.3 - ld)), 0.18, 0.02, 6, hood);
    // Brass clasp at the throat where the hood gathers.
    sphere(v3(base.x + f.x * (0.3 + ld), 1.46 + bob, base.z + f.z * (0.3 + ld)), 0.055, theme.trimColor);

    // Rolled travel-pack across the small of the back — gear that belongs to any
    // build (the quiver/bow/torch went with the loadout-neutral rework).
    const pb = v3(base.x - f.x * 0.42 - right.x * 0.2, 1.0 + bob, base.z - f.z * 0.42 - right.z * 0.2);
    const pt = v3(base.x - f.x * 0.42 + right.x * 0.2, 1.0 + bob, base.z - f.z * 0.42 + right.z * 0.2);
    rl.drawCapsule(pb, pt, 0.13, 8, 6, rgba(84, 56, 34, 255));
    rl.drawCylinderEx(v3((pb.x + pt.x) / 2, 0.88 + bob, (pb.z + pt.z) / 2), v3((pb.x + pt.x) / 2, 1.13 + bob, (pb.z + pt.z) / 2), 0.145, 0.145, 8, rgba(58, 38, 22, 255));
}

// Emissive hero bits (no shadow): melee swing arc, the warm carry glow, and the
// footing ring. Under the same feet-anchored scale as the body.
fn drawHeroFX(p: *const Player, t: f32) void {
    _ = t;
    const base = p.Pos;
    beginHeroScale(base);
    defer rl.gl.rlPopMatrix();
    const f = mathx.orFacing(p.Facing, 0, -1);

    if (p.rolling()) {
        const tt = p.rollTimer / playermod.rollDur;
        groundRing(v3(base.x, 0.05, base.z), playermod.radius + 0.4 * (1 - tt), rgba(200, 210, 230, mathx.u8f(120 * tt)));
        return;
    }

    // Melee steel, two dialects: the basic strike is ONE foe, so it draws a fencing
    // thrust — point out to full reach, planted, recovered. Cleave draws the wide
    // frontal sweep. Both track atkRange so the steel never lies about reach.
    if (p.swing > 0) {
        const a = 1 - p.swing / playermod.swingDur; // 0 → 1 across the swing
        if (p.swingKind == .thrust) {
            // One foe, one line: a single live rapier — a ghost fan is collinear on a
            // thrust and hides inside the blade. The lunge pose and the 4-frame snap
            // carry the motion.
            const gt = heroThrustAt(p, a);
            rl.drawCylinderEx(gt.hand, gt.tip, 0.05, 0.012, 6, rgba(255, 240, 190, 255));
            // The point catches the light as it plants: full flash at extension.
            steelGlint(gt.tip, 0.12 + 0.26 * gt.ext, 0.4 + 0.6 * gt.ext);
        } else {
            const perp = v3(-f.z, 0, f.x); // hero's left in XZ
            const L = p.atkRange / HERO_SCALE; // full reach, like the thrust tip — steel never lies
            const shoulder = v3(base.x + f.x * 0.25, 1.15, base.z + f.z * 0.25);
            const half = std.math.acos(CLEAVE_ARC_DOT); // sweep exactly the hit cone's half-angle
            // Live edge plus a short fan of trailing ghosts behind it fakes motion blur.
            var i: i32 = 0;
            while (i < 4) : (i += 1) {
                const ga = clampF(a - @as(f32, @floatFromInt(i)) * 0.07, 0, 1);
                const th = half * (1 - 2 * ga);
                const dir = v3(f.x * @cos(th) + perp.x * @sin(th), 0, f.z * @cos(th) + perp.z * @sin(th));
                const rise = 0.32 * @sin(ga * std.math.pi); // blade lifts through the middle of the arc
                const tip = v3(shoulder.x + dir.x * L, shoulder.y + rise, shoulder.z + dir.z * L);
                const fade: f32 = if (i == 0) 1.0 else 0.4 * (1 - @as(f32, @floatFromInt(i)) / 4);
                rl.drawCylinderEx(shoulder, tip, if (i == 0) 0.08 else 0.05, 0.02, 6, rgba(255, 240, 190, mathx.u8f(255 * fade)));
                if (i == 0) sphere(tip, 0.09, rgba(255, 250, 220, 230)); // spark at the live tip
            }
        }
    }

    // Carry glow: the overhead light throws his camera side into self-shadow, so a
    // faint warm wash keeps him readable (he IS the light bearer).
    sphere(v3(base.x, 1.05, base.z), 0.78, rgba(255, 170, 90, 26));
    sphere(v3(base.x, 1.6, base.z), 0.45, rgba(255, 185, 110, 30));

    groundRing(v3(base.x, 0.045, base.z), playermod.radius + 0.15, rgba(150, 190, 255, 90));
}

// Rampart stone profile, all derived from world.MASONRY — frame-invariant, so computed
// once at comptime instead of re-lerping four colors every frame in drawWalls.
const WALL_CAP = lerpColor(world.MASONRY, rgba(170, 168, 160, 255), 0.3);
const WALL_PLINTH = lerpColor(world.MASONRY, rl.Color.black, 0.35);
const WALL_PIER = lerpColor(world.MASONRY, rl.Color.black, 0.18);
const WALL_PIER_CAP = lerpColor(WALL_CAP, rl.Color.white, 0.06);

pub fn drawWalls(w: *const world.World) void {
    const hw = w.HalfW;
    const hd = w.HalfD;
    const wallH = 4.0;
    const t = 1.2;
    const col = world.MASONRY; // one stone for all built structure (palette is gone)
    // North/south walls run the WIDTH; east/west run the DEPTH (rect arenas).
    const segs = [_]rl.Vector3{
        v3(0, wallH / 2, -hd), v3(0, wallH / 2, hd),
        v3(-hw, wallH / 2, 0), v3(hw, wallH / 2, 0),
    };
    const sizes = [_]rl.Vector3{
        v3(hw * 2 + t, wallH, t), v3(hw * 2 + t, wallH, t),
        v3(t, wallH, hd * 2 + t), v3(t, wallH, hd * 2 + t),
    };
    // Stone profile per rampart: a paler capstone overhanging the top, a darker plinth at the foot.
    const cap = WALL_CAP;
    const plinth = WALL_PLINTH;
    for (segs, sizes) |seg, size| {
        rl.drawCubeV(seg, size, col);
        rl.drawCubeV(v3(seg.x, wallH + 0.14, seg.z), v3(size.x + 0.35, 0.28, size.z + 0.35), cap);
        rl.drawCubeV(v3(seg.x, 0.3, seg.z), v3(size.x + 0.22, 0.6, size.z + 0.22), plinth);
    }
    // Buttress piers every few strides give the ramparts a masonry rhythm instead of one slab.
    const pier = WALL_PIER;
    const pierCap = WALL_PIER_CAP;
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

const BOB_AMP = 0.05; // walk-bob amplitude, shared by heroBob + monsterBob so they can't drift
const MONSTER_TORSO_BASE = 0.4;
const MONSTER_HEAD_GAP = 0.25;

fn monsterBob(m: *const Monster) f32 {
    return BOB_AMP * sinf(m.bob);
}

// World Y of a point up the drawn torso (frac 0=feet base, ~1=shoulders). FX anchor —
// distinct from the firebolt HITBOX center, which deliberately omits MONSTER_TORSO_BASE.
fn monsterChestY(m: *const Monster, frac: f32) f32 {
    return m.Pos.y + MONSTER_TORSO_BASE + m.Height * frac;
}

// The pib's knife arm through every pose, in one place: body draw, FX glint, and swing
// afterimage all call this so they can't disagree.
//
// The arc IS the pib's entire telegraph: rest shoulders the blade near-vertical; windup
// hauls it back and UP behind the shoulder; the swing whips it around the front (damage
// at midpoint, where it crosses you); flee waves it overhead.
const PibGrip = struct { hand: rl.Vector3, tip: rl.Vector3, out: rl.Vector3 };

// Swing-arc azimuth anchors in the body frame (0 = right, pi/2 = ahead): cocked behind
// the shoulder, across the front, through to the far left. Front-crossing = arc
// midpoint, where updateMonster lands the damage.
const PIB_A_REST = 0.25;
const PIB_A_COCK = -0.9;
const PIB_A_END = 2.4;

fn pibGripAt(m: *const Monster, wp: f32, sp: f32) PibGrip {
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    var a: f32 = PIB_A_REST;
    var handY: f32 = MONSTER_TORSO_BASE + 0.42 + monsterBob(m);
    var reach: f32 = m.Radius * 0.95;
    var up: f32 = 0.66; // blade tip's rise off the grip...
    var out: f32 = 0.05; // ...and its lean along the swing's radial
    if (sp > 0) {
        const e = 1 - (1 - sp) * (1 - sp); // the whip: fast out of the cock, easing late
        a = PIB_A_COCK + (PIB_A_END - PIB_A_COCK) * e;
        handY += 0.55 * (1 - e); // falls from the cocked height through the cut
        reach = m.Radius * (0.95 + 0.4 * sinf(e * std.math.pi)); // arm extends mid-arc
        up = 0.1 + 0.31 * (1 - clampF(sp * 3, 0, 1)); // blade levels out into the slash
        out = 0.6;
    } else if (wp > 0) {
        a = PIB_A_REST + (PIB_A_COCK - PIB_A_REST) * wp;
        handY += 0.55 * wp;
        up = 0.66 - 0.25 * wp;
        out = 0.05 + 0.15 * wp;
    } else if (m.fleeing()) {
        a = PIB_A_REST - 0.4 + 0.5 * sinf(m.bob * 2.7); // waved overhead as it runs
        handY += 0.62 + 0.06 * sinf(m.bob * 5);
        up = 0.7;
        out = 0;
    }
    const dir = v3(right.x * cosf(a) + f.x * sinf(a), 0, right.z * cosf(a) + f.z * sinf(a));
    const hand = v3(m.Pos.x + dir.x * reach, handY, m.Pos.z + dir.z * reach);
    return .{
        .hand = hand,
        .tip = v3(hand.x + dir.x * out, hand.y + up, hand.z + dir.z * out),
        .out = dir,
    };
}

fn pibGrip(m: *const Monster) PibGrip {
    return pibGripAt(m, m.windupProgress(), m.swingProgress());
}

// The archer's bow through idle and draw, in one place: body pass, FX glint, and arrow
// spawn all read this (same contract as pibGrip). The bow IS the skeleton's whole
// threat language — it tracks the aim, the string draws, the head heats.
const SkelBow = struct {
    grip: rl.Vector3, // bow hand, held out front along the aim
    nock: rl.Vector3, // string hand: slides back as the draw builds
    head: rl.Vector3, // arrowhead past the bow — the glint and the loosed arrow ride here
    axis: rl.Vector3, // unit bow axis (canted): tips sit at grip +/- axis * BOW_HALF
};
const BOW_HALF = 0.62;

fn skelBow(m: *const Monster) SkelBow {
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    const wp = m.windupProgress();
    const gy = MONSTER_TORSO_BASE + (m.Height - 0.5) * 0.72 + monsterBob(m);
    const grip = v3(m.Pos.x + f.x * (m.Radius + 0.5), gy, m.Pos.z + f.z * (m.Radius + 0.5));
    // Canted ~35 deg off vertical so the top-down camera sees the full arc and string,
    // not a vertical bow edge-on.
    const axis = v3(right.x * 0.574, 0.819, right.z * 0.574);
    return .{
        .grip = grip,
        .nock = v3(grip.x - f.x * (0.18 + 0.42 * wp), gy - 0.02, grip.z - f.z * (0.18 + 0.42 * wp)),
        .head = v3(grip.x + f.x * 0.34, gy + 0.02, grip.z + f.z * 0.34),
        .axis = axis,
    };
}
fn monsterHeadY(m: *const Monster, shrink: f32) f32 {
    return MONSTER_TORSO_BASE + (m.Height - 0.5) * shrink + MONSTER_HEAD_GAP * shrink + monsterBob(m);
}

// How far each kind's head juts FORWARD of the spine (posture is silhouette). Shared
// with the FX pass so the glowing eyes sit on the drawn face.
fn monsterHeadFwd(m: *const Monster) f32 {
    return switch (m.Kind) {
        .zombie => m.Radius * 0.6,
        .brute => m.Radius * 0.3,
        .fallen => m.Radius * 0.18,
        .skeleton => 0,
    };
}

// How far the torso TOP (and head/hump/shoulders hung off it) leans off vertical this
// frame, in world XZ. Posture in motion: pib waddle-roll, zombie list + slam pitch.
// Shared by the body and FX passes so the eyes ride the leaning head.
fn monsterTorsoLean(m: *const Monster) rl.Vector3 {
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    switch (m.Kind) {
        .fallen => {
            const roll = sinf(m.bob * 1.6) * 0.07;
            return v3(right.x * roll, 0, right.z * roll);
        },
        .zombie => {
            const sway = sinf(m.bob * 0.55) * 0.2;
            var pitch: f32 = 0.1; // resting slouch, ahead of the hunch
            if (m.swing > 0) {
                const e = 1 - (1 - m.swingProgress()) * (1 - m.swingProgress());
                pitch = -0.18 + 0.6 * e; // the whole body crashes into the slam
            } else if (m.windup > 0) {
                pitch = 0.1 - 0.28 * m.windupProgress(); // rears back under the raise
            }
            return v3(right.x * sway + f.x * pitch, 0, right.z * sway + f.z * pitch);
        },
        .skeleton => {
            // The archer leans INTO the draw, weight toward the target as the string comes back.
            const wl = 0.14 * m.windupProgress();
            return v3(f.x * wl, 0, f.z * wl);
        },
        // Exhaustive: a new kind must make a lean decision here, not silently default.
        .brute => return mathx.zero3,
    }
}

// Body + per-kind silhouette. Every appendage is drawn here (not FX) so it exists in
// BOTH the depth and lit passes: horns and arms cast. Body lifted by terrain height.
// (pub: the editor draws encounter previews with the same bodies.)
pub fn drawMonsterBody(m: *const Monster, highlight: bool) void {
    // Flush the batch NOW, while the matrix stack is clean. rlgl uploads matModel from
    // the CURRENT stack at every flush, and the scene shader derives all lighting from
    // matModel against world-space verts (correct only at identity). A mid-body overflow
    // inside this pushMatrix once lit the whole scene through the transform (torch/fog
    // blew out). Unconditional flush, not a headroom check: a reservation was too easy
    // to under-provision (the hero alone is >6k verts).
    rl.gl.rlDrawRenderBatchActive();
    rl.gl.rlPushMatrix();
    defer rl.gl.rlPopMatrix();
    rl.gl.rlTranslatef(0, m.Pos.y, 0);
    const bob = monsterBob(m);
    var col = m.Color;
    // Selected-target wash goes on FIRST, as a base: the state tints below (hit-flash,
    // threat flush) still layer over it, so being targeted never hides a wind-up.
    if (highlight) col = lerpColor(col, TARGET_TINT, 0.4);
    var shrink: f32 = 1;
    if (m.dying) {
        shrink = clampF(m.deathTimer / monster.monster_death_fade, 0.12, 1);
    } else if (m.hitFlash > 0) {
        col = lerpColor(col, rl.Color.white, 0.75);
    } else if (m.windup > 0) {
        col = lerpColor(col, THREAT_TINT, 0.35 + 0.45 * m.windupProgress());
    } else if (m.swing > 0) {
        // The flush holds through the cut and drains with the follow-through.
        col = lerpColor(col, THREAT_TINT, 0.8 * (1 - m.swingProgress()));
    }
    const htop = (m.Height - 0.5) * shrink;
    const x = m.Pos.x;
    const z = m.Pos.z;
    const f = mathx.orFacing(m.Facing, 0, 1);
    const right = mathx.perpXZ(f);
    const dark = lerpColor(col, rl.Color.black, 0.3);
    if (m.dying) {
        // The felled body drains into a dark pool that spreads as the corpse fades.
        const spread = m.Radius * (0.55 + 1.25 * (1 - shrink));
        rl.drawCylinderEx(v3(x, 0.012, z), v3(x, 0.03, z), spread, spread, 16, rgba(74, 12, 14, 255));
    }
    // Torso top carries the frame's lean; shrink collapses it in the death fade. The
    // skeleton draws GAUNT — a slimmer spine than its hitbox, width carried by fittings.
    const lean = monsterTorsoLean(m);
    const torsoR = if (m.Kind == .skeleton) m.Radius * 0.72 else m.Radius;
    rl.drawCapsule(v3(x, MONSTER_TORSO_BASE + bob, z), v3(x + lean.x * shrink, MONSTER_TORSO_BASE + htop + bob, z + lean.z * shrink), torsoR, 8, 4, col);
    const headY = monsterHeadY(m, shrink);
    const headR = m.Radius * 0.7 * shrink;
    // Head sits forward of the spine per-kind and rides the torso lean; face features hang off this center.
    const fwd = monsterHeadFwd(m) * shrink;
    const hcx = x + f.x * fwd + lean.x * shrink;
    const hcz = z + f.z * fwd + lean.z * shrink;
    sphere(v3(hcx, headY, hcz), headR, col);

    switch (m.Kind) {
        // Pib: a cute little knife pig — ears, pink snout, curl of tail, trotters under a
        // waddle — with a dangerous knife whose cocked-back arc is its whole telegraph.
        .fallen => {
            const gait = m.bob * 1.6;
            const waddle = sinf(gait) * 0.05; // side-to-side toddle
            const hx = hcx + right.x * waddle;
            const hz = hcz + right.z * waddle;
            // Triangle ears pointing UP — side-mounted ears would vanish from the top-down camera.
            for ([_]f32{ -1, 1 }) |s| {
                const eb = v3(hx + right.x * headR * 0.55 * s, headY + headR * 0.5, hz + right.z * headR * 0.55 * s);
                rl.drawCylinderEx(eb, v3(eb.x + right.x * 0.08 * s - waddle * right.x, eb.y + 0.26 * shrink, eb.z + right.z * 0.08 * s - waddle * right.z), 0.1 * shrink, 0.0, 5, lerpColor(col, rgba(255, 150, 150, 255), 0.35));
            }
            // Snout: a proud pink button, stuck well out front.
            sphere(v3(hx + f.x * headR * 1.0, headY - headR * 0.05, hz + f.z * headR * 1.0), headR * 0.4 * shrink, rgba(238, 148, 148, 255));
            // Curly tail nub, offset opposite the waddle so it wags as it walks.
            const tail = v3(x - f.x * m.Radius * 1.05 - right.x * waddle * 2, MONSTER_TORSO_BASE + 0.25 + bob, z - f.z * m.Radius * 1.05 - right.z * waddle * 2);
            sphere(tail, 0.09 * shrink, lerpColor(col, rgba(255, 150, 150, 255), 0.35));
            // Trotter feet under the belly, stepping in antiphase — dark toes poking past the silhouette.
            const hoof = lerpColor(col, rl.Color.black, 0.35);
            for ([_]f32{ -1, 1 }) |s| {
                const step = sinf(gait + s * 1.57) * 0.16;
                sphere(v3(x + f.x * (0.18 + step) + right.x * 0.28 * s, 0.09, z + f.z * (0.18 + step) + right.z * 0.28 * s), 0.1 * shrink, hoof);
            }
            const armCol = lerpColor(col, rl.Color.black, 0.15);
            // The knife: a comically OVERSIZED blade, shouldered on the march, cocked back
            // as the strike builds, whipped around the front. Big blade on a small pig
            // reads at gameplay zoom AND is the pib's whole threat language.
            const grip = pibGrip(m);
            const hand = grip.hand;
            const tip = grip.tip;
            // The knife arm has an ELBOW: two segments around a joint pushed out from the
            // spine, so it reads as an arm articulating, not a stick pivoting.
            const sh = v3(x + right.x * m.Radius * 0.6, MONSTER_TORSO_BASE + 0.28 + bob, z + right.z * m.Radius * 0.6);
            const wrist = v3(hand.x, hand.y - 0.08, hand.z);
            const eo = dirXZ(v3(x, 0, z), v3((sh.x + wrist.x) * 0.5, 0, (sh.z + wrist.z) * 0.5));
            const elbow = v3((sh.x + wrist.x) * 0.5 + eo.x * 0.13, (sh.y + wrist.y) * 0.5 - 0.05 * shrink, (sh.z + wrist.z) * 0.5 + eo.z * 0.13);
            rl.drawCapsule(sh, elbow, 0.09 * shrink, 6, 4, armCol);
            rl.drawCapsule(elbow, wrist, 0.08 * shrink, 6, 4, armCol);
            sphere(elbow, 0.095 * shrink, armCol);
            // The off arm: a stubby counter-swinging trotter, thrown up beside the knife on panic.
            const osh = v3(x - right.x * m.Radius * 0.6, MONSTER_TORSO_BASE + 0.3 + bob, z - right.z * m.Radius * 0.6);
            var ohand = v3(osh.x + f.x * (0.14 + sinf(gait) * 0.14) - right.x * 0.1, osh.y + 0.04, osh.z + f.z * (0.14 + sinf(gait) * 0.14) - right.z * 0.1);
            if (m.fleeing() and m.windup <= 0 and m.swing <= 0) {
                ohand = v3(osh.x - right.x * 0.16 + f.x * 0.05, osh.y + 0.5 + 0.05 * sinf(m.bob * 5 + 1.3), osh.z - right.z * 0.16 + f.z * 0.05);
            }
            rl.drawCapsule(osh, ohand, 0.075 * shrink, 6, 4, armCol);
            // Leather grip with a brass pommel bead.
            rl.drawCylinderEx(v3(hand.x, hand.y - 0.15, hand.z), v3(hand.x, hand.y + 0.05, hand.z), 0.06 * shrink, 0.055 * shrink, 5, rgba(70, 50, 34, 255));
            sphere(v3(hand.x, hand.y - 0.17, hand.z), 0.06 * shrink, theme.trimColor);
            // Crossguard: a brass bar across the blade root, perpendicular to the radial so it stays square.
            const gd = mathx.perpXZ(grip.out);
            rl.drawCylinderEx(v3(hand.x - gd.x * 0.17, hand.y + 0.06, hand.z - gd.z * 0.17), v3(hand.x + gd.x * 0.17, hand.y + 0.06, hand.z + gd.z * 0.17), 0.04 * shrink, 0.04 * shrink, 4, theme.trimColor);
            // The blade: bright cold steel to the point, a pale bevel up the spine so it
            // catches light. (Death fade shortens it toward the hand.)
            const tipDrawn = v3(hand.x + (tip.x - hand.x) * shrink, hand.y + (tip.y - hand.y) * shrink, hand.z + (tip.z - hand.z) * shrink);
            rl.drawCylinderEx(v3(hand.x, hand.y + 0.07, hand.z), tipDrawn, 0.095 * shrink, 0.0, 5, rgba(206, 214, 228, 255));
            rl.drawCylinderEx(v3(hand.x + f.x * 0.03, hand.y + 0.1, hand.z + f.z * 0.03), tipDrawn, 0.032 * shrink, 0.0, 4, rgba(240, 246, 252, 255));
        },
        // Zombie: a lumbering hunch that lists as it shuffles, with a two-handed OVERHEAD
        // slam whose long raise is its entire telegraph.
        .zombie => {
            const shY = MONSTER_TORSO_BASE + htop * 0.8 + bob;
            const flesh = lerpColor(col, rgba(205, 215, 165, 255), 0.3); // paler rot
            const lurch = m.bob * 0.55; // the slow heave of the lumber
            // The hump: a swollen back over the shoulders, shoving the head forward and down.
            sphere(v3(x - f.x * m.Radius * 0.4 + lean.x * shrink, MONSTER_TORSO_BASE + htop * 0.98 + bob, z - f.z * m.Radius * 0.4 + lean.z * shrink), m.Radius * 0.8 * shrink, lerpColor(col, rl.Color.black, 0.15));
            // Arms: elbowed, claw-tipped, asymmetric at rest (symmetry reads "healthy").
            // Windup hauls both overhead; the swing crashes them down to the impact point
            // resolveMonsterAttack kicks its dust from.
            const wp = m.windupProgress();
            const sp = m.swingProgress();
            for ([_]f32{ -1, 1 }) |s| {
                const sh = v3(x + (right.x * m.Radius * 0.7 * s + lean.x) * shrink, shY, z + (right.z * m.Radius * 0.7 * s + lean.z) * shrink);
                const armReach: f32 = if (s > 0) 0.9 else 0.68;
                const reach = armReach + sinf(lurch + s * 1.6) * 0.16;
                var hand = v3(sh.x + f.x * reach * shrink, shY - 0.12, sh.z + f.z * reach * shrink);
                if (sp > 0) {
                    const e = 1 - (1 - sp) * (1 - sp); // crash out of the raise
                    const hTop = v3(x + right.x * 0.4 * s - f.x * 0.2, headY + 0.85 * shrink, z + right.z * 0.4 * s - f.z * 0.2);
                    const hGnd = v3(x + f.x * (m.Radius + ZOMBIE_SLAM_FWD) + right.x * 0.3 * s, 0.22, z + f.z * (m.Radius + ZOMBIE_SLAM_FWD) + right.z * 0.3 * s);
                    hand = v3(hTop.x + (hGnd.x - hTop.x) * e, hTop.y + (hGnd.y - hTop.y) * e, hTop.z + (hGnd.z - hTop.z) * e);
                } else if (wp > 0) {
                    const hTop = v3(x + right.x * 0.4 * s - f.x * 0.2, headY + 0.85 * shrink, z + right.z * 0.4 * s - f.z * 0.2);
                    hand = v3(hand.x + (hTop.x - hand.x) * wp, hand.y + (hTop.y - hand.y) * wp, hand.z + (hTop.z - hand.z) * wp);
                }
                // Elbow: pushed out from the spine and sagging — the arm hangs heavy.
                const eo = dirXZ(v3(x, 0, z), v3((sh.x + hand.x) * 0.5, 0, (sh.z + hand.z) * 0.5));
                const elbow = v3((sh.x + hand.x) * 0.5 + eo.x * (0.16 + 0.14 * wp), (sh.y + hand.y) * 0.5 - 0.1 * shrink * (1 - wp), (sh.z + hand.z) * 0.5 + eo.z * (0.16 + 0.14 * wp));
                rl.drawCapsule(sh, elbow, 0.13 * shrink, 6, 4, flesh);
                rl.drawCapsule(elbow, hand, 0.11 * shrink, 6, 4, flesh);
                sphere(elbow, 0.13 * shrink, flesh);
                // A knotted claw of a hand — the slam needs a visible fist to follow.
                sphere(hand, 0.16 * shrink, lerpColor(flesh, rl.Color.black, 0.2));
            }
            // Feet: one stepping, one DRAGGING — the stiff leg never lifts into a stride.
            const bootCol = lerpColor(col, rl.Color.black, 0.4);
            for ([_]f32{ -1, 1 }) |s| {
                var step = sinf(lurch + s * 1.57) * 0.22;
                if (s < 0) step = clampF(step, -0.22, 0.06);
                sphere(v3(x + f.x * (0.1 + step) + right.x * 0.3 * s, 0.09, z + f.z * (0.1 + step) + right.z * 0.3 * s), 0.13 * shrink, bootCol);
            }
            // A slack jaw hanging off the front of the skull: the head lolls.
            sphere(v3(hcx + f.x * headR * 0.85, headY - headR * 0.5, hcz + f.z * headR * 0.85), headR * 0.38, flesh);
        },
        // Archer: a gaunt bone frame behind a hunter's bow — canted arc, live string, both
        // arms on it. The rig points where it aims; the draw is the whole shot warning.
        .skeleton => {
            const wp = m.windupProgress();
            const bow = skelBow(m);
            const boneCol = lerpColor(col, rl.Color.white, 0.15);
            // Pale ashwood: the bow must read against dark ground — it's the whole threat silhouette.
            const bowCol = rgba(158, 118, 68, 255);
            // Bow limbs: swept back off the canted axis, tapering. (Death fade folds toward the grip.)
            const tipU = v3(bow.grip.x + (bow.axis.x * BOW_HALF - f.x * 0.14) * shrink, bow.grip.y + bow.axis.y * BOW_HALF * shrink, bow.grip.z + (bow.axis.z * BOW_HALF - f.z * 0.14) * shrink);
            const tipD = v3(bow.grip.x - (bow.axis.x * BOW_HALF + f.x * 0.14) * shrink, bow.grip.y - bow.axis.y * BOW_HALF * shrink, bow.grip.z - (bow.axis.z * BOW_HALF + f.z * 0.14) * shrink);
            rl.drawCylinderEx(bow.grip, tipU, 0.07 * shrink, 0.025 * shrink, 5, bowCol);
            rl.drawCylinderEx(bow.grip, tipD, 0.07 * shrink, 0.025 * shrink, 5, bowCol);
            // The string: tip to tip through the nock hand. Rest = nearly straight, draw
            // vees it back — THE aggression cue, readable because the bow is canted.
            const stringCol = rgba(235, 235, 245, 255);
            rl.drawCylinderEx(tipU, bow.nock, 0.02, 0.02, 3, stringCol);
            rl.drawCylinderEx(bow.nock, tipD, 0.02, 0.02, 3, stringCol);
            // Bow arm: off shoulder straight out to the grip, locked.
            const shY = MONSTER_TORSO_BASE + htop * 0.85 + bob;
            const shL = v3(x - right.x * m.Radius * 0.85, shY, z - right.z * m.Radius * 0.85);
            const shR = v3(x + right.x * m.Radius * 0.85, shY, z + right.z * m.Radius * 0.85);
            rl.drawCapsule(shL, v3(bow.grip.x, bow.grip.y - 0.02, bow.grip.z), 0.065 * shrink, 6, 4, boneCol);
            // Draw arm: hangs at the hip until a shot telegraphs, then hauls the string
            // back, elbow flaring high.
            const reachT = clampF(wp * 2.5, 0, 1); // hand finds the string early in the draw
            const rest = v3(x + right.x * m.Radius * 0.95 + f.x * 0.1, MONSTER_TORSO_BASE + htop * 0.35 + bob, z + right.z * m.Radius * 0.95 + f.z * 0.1);
            const dhand = v3(rest.x + (bow.nock.x - rest.x) * reachT, rest.y + (bow.nock.y - rest.y) * reachT, rest.z + (bow.nock.z - rest.z) * reachT);
            const delbow = v3((shR.x + dhand.x) * 0.5 - f.x * (0.1 + 0.2 * wp) + right.x * 0.1, (shR.y + dhand.y) * 0.5 + 0.08 * reachT, (shR.z + dhand.z) * 0.5 - f.z * (0.1 + 0.2 * wp) + right.z * 0.1);
            rl.drawCapsule(shR, delbow, 0.065 * shrink, 6, 4, boneCol);
            rl.drawCapsule(delbow, dhand, 0.055 * shrink, 6, 4, boneCol);
            sphere(delbow, 0.07 * shrink, boneCol);
            // The nocked arrow rides the string back — shaft, pale head, grey fletch. Says
            // a shot is coming AND from where.
            if (m.windup > 0) {
                rl.drawCylinderEx(bow.nock, bow.head, 0.035, 0.035, 4, rgba(165, 128, 82, 255));
                rl.drawCylinderEx(bow.head, v3(bow.head.x + f.x * 0.16, bow.head.y, bow.head.z + f.z * 0.16), 0.07, 0.0, 4, rgba(235, 230, 210, 255));
                rl.drawCylinderEx(bow.nock, v3(bow.nock.x + f.x * 0.14, bow.nock.y, bow.nock.z + f.z * 0.14), 0.085, 0.02, 4, rgba(210, 210, 220, 230));
            }
            // Quiver: a fan of shafts over the off shoulder — reads as an archer from BEHIND too.
            for ([_]f32{ -0.14, 0.0, 0.14 }) |qa| {
                const qb = v3(x - f.x * m.Radius * 0.55 - right.x * m.Radius * 0.35, MONSTER_TORSO_BASE + htop * 0.6 + bob, z - f.z * m.Radius * 0.55 - right.z * m.Radius * 0.35);
                const qt = v3(qb.x + (-f.x * 0.22 + right.x * qa) * shrink, qb.y + 0.62 * shrink, qb.z + (-f.z * 0.22 + right.z * qa) * shrink);
                rl.drawCylinderEx(qb, qt, 0.02 * shrink, 0.02 * shrink, 3, rgba(126, 96, 62, 255));
                sphere(qt, 0.045 * shrink, rgba(205, 205, 215, 255));
            }
            // Bony shoulder knobs so the pale frame looks skeletal, not smooth.
            for ([_]f32{ -1, 1 }) |s| {
                sphere(v3(x + right.x * m.Radius * 0.85 * s, shY, z + right.z * m.Radius * 0.85 * s), 0.14 * shrink, boneCol);
            }
            // Ribcage: three darker bands across the front — the detail that says "bones", not "pale ghost".
            const ribCol = lerpColor(col, rl.Color.black, 0.35);
            for ([_]f32{ 0.42, 0.58, 0.74 }) |rf| {
                const ry = MONSTER_TORSO_BASE + htop * rf + bob;
                rl.drawCylinderEx(
                    v3(x + f.x * m.Radius * 0.45 - right.x * m.Radius * 0.62, ry, z + f.z * m.Radius * 0.45 - right.z * m.Radius * 0.62),
                    v3(x + f.x * m.Radius * 0.45 + right.x * m.Radius * 0.62, ry, z + f.z * m.Radius * 0.45 + right.z * m.Radius * 0.62),
                    0.035 * shrink,
                    0.035 * shrink,
                    4,
                    ribCol,
                );
            }
        },
        // Brute: boulder shoulders, ivory tusks, knuckle-dragging arms ahead — a gorilla stance for mass.
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

// A dynamic body is worth drawing inside the torch's CURRENT lit disc (torchR, the
// breathing radius <= TORCH_RADIUS) or when a live fireball lights it. Gated at the
// lit radius (not padded CULL) so bodies never linger as dim silhouettes on dark
// ground — fog shows terrain memory in the "seen" band, never bodies. Static mesh always draws.
fn bodyVisible(pos: rl.Vector3, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) bool {
    // Squared compares: the most-called cull test (every body, each pass), a pure threshold — no @sqrt.
    if (dist2XZ(pos, lightXZ) <= torchR * torchR) return true;
    return fp.intensity > 0 and dist2XZ(pos, fp.pos) <= fp.radius * fp.radius;
}

// A flat ring on the floor (XY circle rotated onto XZ). One spelling of the axis/angle
// so a stray literal can't tilt a single reticle/telegraph off the ground. (pub: the
// editor draws its author-time rings through the same helper, not raw drawCircle3D.)
pub fn groundRing(center: rl.Vector3, r: f32, col: rl.Color) void {
    rl.drawCircle3D(center, r, v3(1, 0, 0), 90, col);
}

// A steel point catching the light: a pin-bright core with thin tapered flash rays.
// A glint is a STAR, never a ball — stacked fat spheres read as geometry stuck to the
// blade. Long vertical pair + a shorter XZ-diagonal pair (iso camera yaw is fixed, so
// one world diagonal always reads as a slash across the point). Friend and foe share
// this so every blade speaks the same light.
fn steelGlint(pos: rl.Vector3, size: f32, intensity: f32) void {
    const col = rgba(255, 255, 245, mathx.u8f(140 + 115 * intensity));
    sphere(pos, 0.028 + 0.022 * intensity, col);
    const dx = 0.7071 * size * 0.6;
    for ([_][3]f32{ .{ 0, size, 0 }, .{ 0, -size, 0 }, .{ dx, 0, -dx }, .{ -dx, 0, dx } }) |d| {
        rl.drawCylinderEx(pos, v3(pos.x + d[0], pos.y + d[1], pos.z + d[2]), 0.016, 0, 4, col);
    }
}

// Everything that casts a shadow, submitted in one place so a new caster can't be
// added to one depth pass and forgotten in the other.
fn submitCasters(g: *Game, ms: []const Monster, lightGround: rl.Vector3, torchR: f32, fp: tl.FireParams, drawHero: bool) void {
    g.sceneMesh.drawDepth();
    drawMonstersCast(ms, lightGround, torchR, fp);
    if (drawHero) drawHeroBody(&g.p);
}

// Depth pass: visible living bodies cast. Bodies neither near the torch nor fireball-lit
// render black, so shadowing them is pointless.
fn drawMonstersCast(ms: []const Monster, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (m.dying) continue;
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        drawMonsterBody(m, false); // depth pass: color unused, so never highlight here
    }
}

fn drawMonstersLit(ms: []const Monster, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams, targetID: i32) void {
    for (ms) |*m| {
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        drawMonsterBody(m, m.id == targetID);
    }
}

// Emissive pass (no shadow): glowing eyes + the red attack telegraph + boss ring +
// the reticle under the SELECTED target (pairs with the body wash + HUD plate).
fn drawMonstersFX(ms: []const Monster, lightXZ: rl.Vector3, pPos: rl.Vector3, torchR: f32, fp: tl.FireParams, targetID: i32, t: f32) void {
    for (ms) |*m| {
        if (m.dying or !m.alive()) continue;
        if (!bodyVisible(m.Pos, lightXZ, torchR, fp)) continue;
        // Lift this monster's FX onto its terrain height; anything aimed at the PLAYER compensates back out.
        rl.gl.rlPushMatrix();
        defer rl.gl.rlPopMatrix();
        rl.gl.rlTranslatef(0, m.Pos.y, 0);
        if (m.id == targetID) {
            // Bright double reticle at the feet — a crisp, pulsing bracket that reads as
            // "locked on", distinct from the boss's red ring and any telegraph.
            const pulse = 0.1 * sinf(t * 5);
            const tc = TARGET_TINT;
            groundRing(v3(m.Pos.x, 0.05, m.Pos.z), m.Radius + 0.34 + pulse, mathx.withAlpha(tc, 235));
            groundRing(v3(m.Pos.x, 0.05, m.Pos.z), m.Radius + 0.5 + pulse, mathx.withAlpha(tc, 120));
        }
        if (m.boss) {
            groundRing(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.4, rgba(255, 60, 60, 200));
            groundRing(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.55 + 0.1 * sinf(t * 3), rgba(255, 60, 60, 90));
        }
        // Ground telegraph — only for kinds that still use one. Pib/zombie/skeleton carry
        // their warning entirely in the body anim: no marking for them, by design.
        if (m.windup > 0 and !monster.animTelegraph(m.Kind)) {
            const tp = m.windupProgress();
            const a = mathx.u8f(clampF(110 + 130 * tp, 0, 255));
            if (m.Ranged) {
                // Aim the threat beam at the player's true elevation (compensating for the
                // lifted frame) so it climbs at a rampart.
                rl.drawCylinderEx(v3(m.Pos.x, 1.2, m.Pos.z), v3(pPos.x, pPos.y - m.Pos.y + 0.3, pPos.z), 0.05, 0.05, 4, rgba(255, 70, 50, a));
            } else {
                // Kill zone fills as the blow comes down: a red disc swelling to true reach, ringed at the edge.
                const rr = meleeReach(m.atkRange, playermod.radius);
                rl.drawCylinderEx(v3(m.Pos.x, 0.015, m.Pos.z), v3(m.Pos.x, 0.045, m.Pos.z), rr * tp, rr * tp, 24, rgba(255, 50, 30, mathx.u8f(26 + 44 * tp)));
                groundRing(v3(m.Pos.x, 0.09, m.Pos.z), rr, rgba(255, 60, 40, a));
                groundRing(v3(m.Pos.x, 0.09, m.Pos.z), rr * tp, rgba(255, 100, 50, a));
            }
        }
        // The pib knife catches the light: a white star at the point, flaring as the cock
        // builds and the cut flies. The knife IS the telegraph — never lose track of it.
        if (m.Kind == .fallen) {
            const wp = m.windupProgress();
            const sp = m.swingProgress();
            const tip = pibGrip(m).tip;
            const flare = maxF(wp, sinf(sp * std.math.pi)); // peaks as the blade crosses you
            const tw = 0.7 + 0.3 * sinf(t * 9 + m.Pos.x * 3 + m.Pos.z * 5); // idle twinkle
            steelGlint(tip, (0.16 + 0.3 * flare) * tw, 0.35 + 0.65 * flare);
            // The cut leaves a trail of fading tip-ghosts along the arc — reads as a sweep, not a teleport.
            if (sp > 0) {
                var k: f32 = 1;
                while (k <= 5) : (k += 1) {
                    const gsp = sp - k * 0.055;
                    if (gsp <= 0) break;
                    const ghost = pibGripAt(m, 1, gsp).tip;
                    sphere(ghost, 0.05 * (1 - k * 0.15), rgba(235, 240, 250, mathx.u8f(150 - k * 26)));
                }
            }
        }
        // The arrowhead heats as the draw builds — the "you are targeted" cue, ember to flare at full draw.
        if (m.Kind == .skeleton and m.windup > 0) {
            const wp = m.windupProgress();
            const head = skelBow(m).head;
            sphere(head, 0.03 + 0.05 * wp, rgba(255, 235, 200, 255));
            sphere(head, 0.08 + 0.14 * wp, rgba(255, 150, 55, mathx.u8f(50 + 150 * wp)));
        }
        const headY = monsterHeadY(m, 1);
        const f = mathx.orFacing(m.Facing, 0, 1);
        const right = mathx.perpXZ(f);
        // Skeleton sockets burn cold when idle — everyone flares red on the attack.
        const idleEye = if (m.Kind == .skeleton) rgba(150, 225, 255, 255) else rgba(255, 210, 60, 255);
        const eyeCol = if (m.windup > 0 or m.swing > 0) rgba(255, 70, 40, 255) else idleEye;
        // Eyes ride the same forward-shifted, lean-carried head center the body drew.
        const lean = monsterTorsoLean(m);
        const eyeFwd = m.Radius * 0.5 + monsterHeadFwd(m);
        for ([_]f32{ -1, 1 }) |s| {
            const e = v3(m.Pos.x + f.x * eyeFwd + right.x * m.Radius * 0.3 * s + lean.x, headY + 0.02, m.Pos.z + f.z * eyeFwd + right.z * m.Radius * 0.3 * s + lean.z);
            sphere(e, 0.07, eyeCol);
        }
    }
}

// The miasma made visible: churning rot-green blobs filling the DoT footprint over a
// ground stain at the TRUE damage radius — what you see is what hurts, no hard ring.
// Emissive pass like all glow FX; gated at the lit radius.
//
// ADDITIVE with depth WRITES off: gas is glowing vapor, so it may only ADD light. Alpha
// blending DARKENED the lit ground (the cloud "ate" light) and its depth writes clipped
// beams/particles behind each sphere. Depth still TESTED, so walls occlude it.
fn drawGasClouds(g: *Game, lightXZ: rl.Vector3, torchR: f32, fp: tl.FireParams, t: f32) void {
    if (g.gasCount == 0) return;
    rl.beginBlendMode(.additive);
    rl.gl.rlDisableDepthMask();
    defer {
        // endBlendMode FIRST: it flushes the gas geometry, which must still see depth writes off.
        rl.endBlendMode();
        rl.gl.rlEnableDepthMask();
    }
    for (g.gas[0..g.gasCount]) |*gc| {
        if (!bodyVisible(gc.Pos, lightXZ, torchR, fp)) continue;
        const age = GAS_LIFE - gc.life;
        const grow = clampF(age / GAS_GROW, 0.15, 1); // billow up out of the corpse
        const fade = clampF(gc.life / (GAS_LIFE * 0.28), 0, 1); // thin out at the end
        const r = GAS_RADIUS * grow;
        const a = fade * (0.8 + 0.2 * sinf(t * 2.3 + gc.seed)); // slow breathing
        rl.drawCylinderEx(v3(gc.Pos.x, gc.Pos.y + 0.02, gc.Pos.z), v3(gc.Pos.x, gc.Pos.y + 0.05, gc.Pos.z), r, r, 20, mathx.withAlpha(GAS_STAIN_COLOR, mathx.u8f(56 * a)));
        // A bright heart low in the cloud so the hazard reads under the churn. (Additive: overlaps brighten.)
        sphere(v3(gc.Pos.x, gc.Pos.y + 0.45 * grow, gc.Pos.z), r * 0.38 * grow, mathx.withAlpha(GAS_HEART_COLOR, mathx.u8f(62 * a)));
        // Blobs churn on slow per-cloud lissajous seats out to the footprint edge.
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const fi: f32 = @floatFromInt(i);
            const ph = gc.seed + fi * 1.9;
            const orbit = r * (0.18 + 0.11 * fi);
            const bx = gc.Pos.x + cosf(t * (0.5 + 0.09 * fi) + ph) * orbit;
            const bz = gc.Pos.z + sinf(t * (0.4 + 0.07 * fi) + ph * 1.7) * orbit;
            const by = gc.Pos.y + (0.3 + 0.22 * fi) * grow + 0.1 * sinf(t * 1.1 + ph);
            sphere(v3(bx, by, bz), r * (0.5 - 0.05 * fi) * grow, mathx.withAlpha(GAS_BLOB_COLOR, mathx.u8f((48 - 5 * fi) * a)));
        }
    }
}

// Pick the fireball that lights the scene: the first live FIREBOLT, modeled overhead
// (FIRE_HEIGHT above its terrain) so the shadow map stays oriented. intensity 0 => no
// fireball. Only the firebolt is a moving flame — a thrown knife/ice shard/flask is its
// own emissive (drawProjectiles) and must NOT bathe the ground in orange fire light or
// trigger the extra fire depth pass. (The "light blowing out mid-fight" bug was the
// batch overflow, not this — see drawMonsterBody.)
fn fireLight(g: *Game, t: f32) tl.FireParams {
    for (g.projs.items()) |*pr| {
        if (!pr.FromPlayer or pr.Kind != .firebolt) continue;
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
        switch (pr.Kind) {
            .firebolt => {
                // A white-hot heart in a flickering orange corona, a flame tongue trailing. Sparks are particles.
                const flick = 1 + 0.16 * sinf(t * 31 + pr.Pos.x * 5 + pr.Pos.z * 3);
                const tail = v3(pr.Pos.x - pr.Vel.x * 0.055, pr.Pos.y + 0.1, pr.Pos.z - pr.Vel.z * 0.055);
                rl.drawCylinderEx(tail, pr.Pos, 0.04, pr.Radius * 0.75, 6, rgba(255, 120, 30, 120));
                sphere(pr.Pos, pr.Radius * 0.95 * flick, rgba(255, 110, 25, 95));
                sphere(pr.Pos, pr.Radius * 0.6 * flick, rgba(255, 180, 60, 210));
                sphere(pr.Pos, pr.Radius * 0.32, projectile.flameHeartColor);
            },
            .ice_shard => {
                // A cold blue splinter: a faceted core in a pale halo, a short frost wake.
                const tail = v3(pr.Pos.x - pr.Vel.x * 0.05, pr.Pos.y, pr.Pos.z - pr.Vel.z * 0.05);
                rl.drawCylinderEx(tail, pr.Pos, 0.02, pr.Radius * 0.6, 5, mathx.withAlpha(projectile.iceShardColor, 110));
                sphere(pr.Pos, pr.Radius * 0.85, mathx.withAlpha(projectile.iceShardColor, 150));
                sphere(pr.Pos, pr.Radius * 0.42, rgba(235, 250, 255, 255));
            },
            .flask => {
                // A tumbling vial of green venom with a faint glow.
                sphere(pr.Pos, pr.Radius * 0.9, mathx.withAlpha(projectile.toxicColor, 150));
                sphere(pr.Pos, pr.Radius * 0.5, rgba(210, 245, 150, 235));
            },
            .knife, .arrow => {
                // A real shaft laid along its flight, not a floating ball. The knife is a
                // stubby steel blade; the arrow a fletched wooden shaft.
                const inv = 1.0 / maxF(lenXZ(pr.Vel), 1e-4);
                const dx = pr.Vel.x * inv;
                const dz = pr.Vel.z * inv;
                if (pr.Kind == .knife) {
                    const back = v3(pr.Pos.x - dx * 0.22, pr.Pos.y, pr.Pos.z - dz * 0.22);
                    const tip = v3(pr.Pos.x + dx * 0.26, pr.Pos.y, pr.Pos.z + dz * 0.26);
                    rl.drawCylinderEx(v3(pr.Pos.x - dx * 0.9, pr.Pos.y, pr.Pos.z - dz * 0.9), back, 0.006, 0.03, 4, rgba(220, 226, 238, 70));
                    rl.drawCylinderEx(back, tip, 0.045, 0.0, 5, rgba(226, 230, 240, 255)); // blade
                    rl.drawCylinderEx(v3(back.x - dx * 0.07, back.y, back.z - dz * 0.07), back, 0.06, 0.03, 4, rgba(120, 96, 66, 255)); // grip
                } else {
                    const nock = v3(pr.Pos.x - dx * 0.5, pr.Pos.y, pr.Pos.z - dz * 0.5);
                    const tip = v3(pr.Pos.x + dx * 0.28, pr.Pos.y, pr.Pos.z + dz * 0.28);
                    rl.drawCylinderEx(v3(pr.Pos.x - dx * 1.5, pr.Pos.y, pr.Pos.z - dz * 1.5), nock, 0.008, 0.05, 4, rgba(220, 226, 238, 70));
                    rl.drawCylinderEx(nock, tip, 0.035, 0.035, 5, rgba(120, 90, 60, 255));
                    rl.drawCylinderEx(tip, v3(tip.x + dx * 0.16, tip.y, tip.z + dz * 0.16), 0.07, 0.0, 5, rgba(225, 220, 200, 255));
                    rl.drawCylinderEx(nock, v3(nock.x + dx * 0.16, nock.y, nock.z + dz * 0.16), 0.09, 0.02, 4, rgba(200, 200, 210, 220));
                }
            },
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
        // A soft shaft of light stands over every drop so loot reads across the floor.
        // Emissive, breathing slowly in the drop's color.
        const beamCol = switch (d.Kind) {
            .gold => theme.goldColor,
            .health_potion => theme.healthColor,
            .mana_potion => theme.manaColor,
        };
        const pulse = 0.7 + 0.3 * sinf(d.bob * 0.7);
        rl.drawCylinderEx(v3(d.Pos.x, 0.05, d.Pos.z), v3(d.Pos.x, 2.0, d.Pos.z), 0.05, 0.012, 6, mathx.withAlpha(beamCol, mathx.u8f(90 * pulse)));
        rl.drawCylinderEx(v3(d.Pos.x, 0.05, d.Pos.z), v3(d.Pos.x, 1.3, d.Pos.z), 0.14, 0.02, 6, mathx.withAlpha(beamCol, mathx.u8f(34 * pulse)));
        // The beam foreshortens to a dot from the iso camera, so the floor talks: a glow pool plus a crisp ring.
        rl.drawCylinderEx(v3(d.Pos.x, 0.012, d.Pos.z), v3(d.Pos.x, 0.03, d.Pos.z), 0.45, 0.45, 20, mathx.withAlpha(beamCol, mathx.u8f(28 * pulse)));
        groundRing(v3(d.Pos.x, 0.04, d.Pos.z), 0.4 + 0.05 * sinf(d.bob), mathx.withAlpha(beamCol, mathx.u8f(140 * pulse)));
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
                rl.drawCylinderEx(v3(d.Pos.x, y + 0.28, d.Pos.z), v3(d.Pos.x, y + 0.35, d.Pos.z), 0.075, 0.07, 8, theme.corkColor);
            },
        }
    }
}

pub fn drawPortal(w: *const world.World, t: f32) void {
    const pp = w.PortalPos;
    const gy = w.groundY(pp.x, pp.z); // an editor can seat the gate on a ledge — ride its floor
    if (!w.PortalOpen) {
        // Dormant: a dark stone dais with a slow-pulsing rune ring and a dim heart-ember,
        // banked and waiting.
        rl.drawCylinderEx(v3(pp.x, gy + 0.02, pp.z), v3(pp.x, gy + 0.06, pp.z), 2.0, 2.0, 24, rgba(42, 42, 58, 220));
        const pulse = mathx.u8f(70 + 45 * sinf(t * 1.4));
        groundRing(v3(pp.x, gy + 0.09, pp.z), 1.55, rgba(110, 100, 170, pulse));
        groundRing(v3(pp.x, gy + 0.09, pp.z), 1.15, rgba(110, 100, 170, pulse / 2));
        sphere(v3(pp.x, gy + 0.18, pp.z), 0.11 + 0.02 * sinf(t * 1.4), rgba(120, 105, 210, pulse));
        sphere(v3(pp.x, gy + 0.18, pp.z), 0.26, rgba(120, 105, 210, pulse / 4));
        return;
    }
    // Open: a violet vortex built from AIR — a glowing dais, two helix strands up a
    // tapering throat, thin rim rings. (Stacked cylinders read as an opaque blob; points/lines stay airy.)
    rl.drawCylinderEx(v3(pp.x, gy + 0.02, pp.z), v3(pp.x, gy + 0.05, pp.z), 2.3, 2.3, 28, rgba(70, 50, 130, 150));
    rl.drawCylinderEx(v3(pp.x, gy + 0.05, pp.z), v3(pp.x, gy + 0.08, pp.z), 1.9, 1.9, 28, rgba(120, 90, 220, 100));
    var strand: i32 = 0;
    while (strand < 2) : (strand += 1) {
        const sPh: f32 = @floatFromInt(strand);
        var s: i32 = 0;
        while (s < 14) : (s += 1) {
            const f: f32 = @as(f32, @floatFromInt(s)) / 13.0;
            const ang = t * 2.6 + f * 12.0 + sPh * std.math.pi;
            const r = (1.55 - f * 0.95) + 0.08 * sinf(t * 3 + f * 9);
            const y = gy + 0.12 + f * 3.1;
            const pos = v3(pp.x + cosf(ang) * r, y, pp.z + sinf(ang) * r);
            const c = lerpColor(rgba(150, 170, 255, 255), rgba(230, 160, 255, 240), f);
            sphere(pos, 0.17 * (1 - f * 0.4), c);
            sphere(pos, 0.32 * (1 - f * 0.4), mathx.withAlpha(c, 70)); // soft halo
        }
    }
    // Breathing rim rings anchor the throat to the dais.
    groundRing(v3(pp.x, gy + 0.1, pp.z), 1.6 + 0.08 * sinf(t * 2.1), rgba(200, 170, 255, 190));
    groundRing(v3(pp.x, gy + 0.1, pp.z), 1.25 + 0.06 * sinf(t * 2.1 + 1.5), rgba(160, 130, 255, 130));
    // A sky-beam over the gate — the arena's one landmark, a violet column readable across the dark.
    rl.drawCylinderEx(v3(pp.x, gy + 0.1, pp.z), v3(pp.x, gy + 8.0, pp.z), 1.05, 0.28, 12, rgba(150, 110, 255, 26));
    rl.drawCylinderEx(v3(pp.x, gy + 0.1, pp.z), v3(pp.x, gy + 5.4, pp.z), 0.5, 0.12, 10, rgba(200, 170, 255, 44));
    // Three rune-sparks patrol the rim, counter-rotating against the helix.
    var k: i32 = 0;
    while (k < 3) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ang = -t * 1.3 + kf * (std.math.tau / 3.0);
        const rp = v3(pp.x + cosf(ang) * 2.0, gy + 0.3 + 0.1 * sinf(t * 2.2 + kf * 2.1), pp.z + sinf(ang) * 2.0);
        sphere(rp, 0.08, rgba(225, 200, 255, 235));
        sphere(rp, 0.2, rgba(180, 140, 255, 70));
    }
}

// Per-area firefly swarm color (one per campaign map, areaIndex-keyed): moor green, plains
// wisps, stony amber, dark-wood green, catacomb violet. Frame-invariant — module const.
const FIREFLY_COLS = [_]rl.Color{
    rgba(180, 220, 100, 255),
    rgba(170, 205, 255, 255),
    rgba(205, 210, 120, 255),
    rgba(150, 235, 110, 255),
    rgba(165, 150, 255, 255),
};

// Fireflies: tiny blinking lights adrift OUTSIDE the torch disc. Pure function of
// time+index (no state), each wandering a slow lissajous around a fixed seat, so the
// unexplored black reads as living night.
fn drawFireflies(g: *const Game, t: f32) void {
    const DARK_WOOD_AREA = 3; // campaign-order index of the map whose swarm teems (keyed to maps/*.map order)
    const col = FIREFLY_COLS[g.areaIndex % FIREFLY_COLS.len];
    const n: usize = if (g.areaIndex == DARK_WOOD_AREA) 26 else 16;
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

// LIGHT LOG (main menu → Debug Log): a measuring instrument. Each playing frame stashes
// the exact lp/fp/cam (drawWorld), then after endDrawing reads back the frame, measures
// the lit disc (dark-edge px along 4 rays + color), logs that with clip planes, torch,
// facing, projectiles, and NaN checks, and exports shots/anomaly_N.png when the radius
// deviates >30% from its rolling median. State and picture land on one line.
var lightLogFile: ?std.fs.File = null;
var dbgLp: tl.LightParams = .{ .pos = mathx.zero3, .radius = 0 };
var dbgFp: tl.FireParams = .{ .pos = mathx.zero3, .radius = 0, .color = mathx.zero3, .intensity = 0 };
var dbgCam: rl.Camera3D = undefined;
var dbgFrame: u64 = 0;
var dbgRadHist: [48]f32 = undefined;
var dbgRadCount: usize = 0;
var dbgRadIdx: usize = 0;
var dbgAnomalies: i32 = 0;

fn toggleDebugLog(g: *Game) void {
    g.debugLog = !g.debugLog;
    if (g.debugLog) {
        // Fresh file per enable, header first so a pasted tail is self-describing.
        if (lightLogFile) |f| f.close();
        lightLogFile = std.fs.cwd().createFile("lightlog.txt", .{ .truncate = true }) catch null;
        if (lightLogFile) |f| f.writeAll("# lightlog v2: fr t dt fps | lpR lpPos fpI fpR fpPos | cam->tgt fov zoom clip | torchXZ pPos face | MEASURED mrad(L,R,U,D) med ring(r,g,b) | projs pb arwN=(x,y,z|vy) | flash shake gas parts mons wind hp | nan\n") catch {};
        dbgFrame = 0;
        dbgRadCount = 0;
        dbgRadIdx = 0;
        dbgAnomalies = 0;
    } else if (lightLogFile) |f| {
        f.close();
        lightLogFile = null;
    }
}

fn nanBad(v: rl.Vector3) bool {
    return std.math.isNan(v.x) or std.math.isNan(v.y) or std.math.isNan(v.z) or
        std.math.isInf(v.x) or std.math.isInf(v.y) or std.math.isInf(v.z);
}

// Walk from screen center along (dx,dy) until 16 consecutive near-black pixels (the fog
// beyond the lit disc); returns the px distance to the dark run, or to the edge.
fn rayDarkEdge(img: *const rl.Image, cx: i32, cy: i32, dx: i32, dy: i32) i32 {
    var d: i32 = 1;
    var darkRun: i32 = 0;
    while (true) : (d += 1) {
        const x = cx + dx * d;
        const y = cy + dy * d;
        if (x < 2 or y < 2 or x >= img.width - 2 or y >= img.height - 2) return d;
        const c = rl.getImageColor(img.*, x, y);
        const lum = @max(@max(@as(i32, c.r), @as(i32, c.g)), @as(i32, c.b));
        if (lum < 26) {
            darkRun += 1;
            if (darkRun >= 16) return d - darkRun;
        } else darkRun = 0;
    }
}

// Post-endDrawing probe: measure the frame that was ACTUALLY presented, write the
// mega-line, and export the frame itself when the measurement jumps.
fn debugFrameProbe(g: *Game) void {
    if (!g.debugLog or g.scene != .playing) return;
    const f = lightLogFile orelse return;
    dbgFrame += 1;
    const img = rl.loadImageFromScreen() catch return;
    defer rl.unloadImage(img);
    const cx = @divTrunc(img.width, 2);
    const cy = @divTrunc(img.height, 2);
    const mL = rayDarkEdge(&img, cx, cy, -1, 0);
    const mR = rayDarkEdge(&img, cx, cy, 1, 0);
    const mU = rayDarkEdge(&img, cx, cy, 0, -1);
    const mD = rayDarkEdge(&img, cx, cy, 0, 1);
    const mAvg: f32 = @as(f32, @floatFromInt(mL + mR + mU + mD)) / 4.0;
    // Disc color: mean RGB on a 12-point ring at 0.55x the extent — hue jumps flag "turns colors".
    var rr: i32 = 0;
    var rg: i32 = 0;
    var rb: i32 = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * (std.math.tau / 12.0);
        const px = cx + @as(i32, @intFromFloat(cosf(a) * mAvg * 0.55));
        const py = cy + @as(i32, @intFromFloat(sinf(a) * mAvg * 0.55));
        const c = rl.getImageColor(img, std.math.clamp(px, 0, img.width - 1), std.math.clamp(py, 0, img.height - 1));
        rr += c.r;
        rg += c.g;
        rb += c.b;
    }
    // Rolling median of the measured extent; deviation beyond +-30% = anomaly.
    var med: f32 = mAvg;
    var anom = false;
    if (dbgRadCount >= 40) {
        var sorted: [48]f32 = undefined;
        const n = @min(dbgRadCount, dbgRadHist.len);
        @memcpy(sorted[0..n], dbgRadHist[0..n]);
        std.mem.sort(f32, sorted[0..n], {}, std.sort.asc(f32));
        med = sorted[n / 2];
        anom = mAvg > med * 1.3 or mAvg < med * 0.7;
    }
    dbgRadHist[dbgRadIdx] = mAvg;
    dbgRadIdx = (dbgRadIdx + 1) % dbgRadHist.len;
    if (dbgRadCount < dbgRadHist.len) dbgRadCount += 1;
    var anomName: []const u8 = "";
    var nbuf: [48]u8 = undefined;
    if (anom and dbgAnomalies < 16) {
        std.fs.cwd().makePath("shots") catch {};
        if (std.fmt.bufPrintZ(&nbuf, "shots/anomaly_{d}.png", .{dbgAnomalies})) |nm| {
            _ = rl.exportImage(img, nm);
            anomName = nm;
            dbgAnomalies += 1;
        } else |_| {}
    }
    // NaN sweep across everything that feeds a draw this frame.
    var nanFlags: [96]u8 = undefined;
    var nanLen: usize = 0;
    const appendNan = struct {
        fn go(bufp: []u8, lenp: *usize, tag: []const u8) void {
            if (lenp.* + tag.len + 1 > bufp.len) return;
            @memcpy(bufp[lenp.*..][0..tag.len], tag);
            lenp.* += tag.len;
            bufp[lenp.*] = ',';
            lenp.* += 1;
        }
    }.go;
    if (nanBad(g.torchXZ)) appendNan(&nanFlags, &nanLen, "torch");
    if (nanBad(g.p.Pos)) appendNan(&nanFlags, &nanLen, "pPos");
    if (nanBad(g.p.Facing)) appendNan(&nanFlags, &nanLen, "face");
    if (nanBad(dbgCam.position) or nanBad(dbgCam.target)) appendNan(&nanFlags, &nanLen, "cam");
    if (nanBad(dbgLp.pos) or std.math.isNan(dbgLp.radius)) appendNan(&nanFlags, &nanLen, "lp");
    var fromPlayer: usize = 0;
    var windups: usize = 0;
    for (g.projs.items()) |*pr| {
        if (pr.FromPlayer) fromPlayer += 1;
        if (nanBad(pr.Pos) or nanBad(pr.Vel)) appendNan(&nanFlags, &nanLen, "proj");
    }
    for (g.liveMonsters()) |*m| {
        if (m.windup > 0) windups += 1;
        if (nanBad(m.Pos) or nanBad(m.Facing)) appendNan(&nanFlags, &nanLen, "mons");
    }
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("fr={d} t={d:.3} dt={d:.1}ms fps={d} | lpR={d:.2} lpPos=({d:.1},{d:.1},{d:.1}) fpI={d:.3} fpR={d:.1} fpPos=({d:.1},{d:.1},{d:.1})", .{
        dbgFrame,        g.elapsed,    rl.getFrameTime() * 1000.0, rl.getFPS(),
        dbgLp.radius,    dbgLp.pos.x,  dbgLp.pos.y,                dbgLp.pos.z,
        dbgFp.intensity, dbgFp.radius, dbgFp.pos.x,                dbgFp.pos.y,
        dbgFp.pos.z,
    }) catch return;
    w.print(" | cam=({d:.1},{d:.1},{d:.1})->({d:.1},{d:.1},{d:.1}) fov={d:.1} zoom={d:.2} clip=({d:.2},{d:.1}) | torch=({d:.2},{d:.2}) p=({d:.2},{d:.2}) face=({d:.2},{d:.2})", .{
        dbgCam.position.x, dbgCam.position.y, dbgCam.position.z,
        dbgCam.target.x,   dbgCam.target.y,   dbgCam.target.z,
        dbgCam.fovy,       g.rig.zoom,        rl.gl.rlGetCullDistanceNear(), rl.gl.rlGetCullDistanceFar(),
        g.torchXZ.x,       g.torchXZ.z,       g.p.Pos.x,                     g.p.Pos.z,
        g.p.Facing.x,      g.p.Facing.z,
    }) catch return;
    w.print(" | mrad=({d},{d},{d},{d}) med={d:.0} ring=({d},{d},{d}) | projs={d} pb={d}", .{
        mL,                mR,                mU, mD, med,
        @divTrunc(rr, 12), @divTrunc(rg, 12), @divTrunc(rb, 12),
        g.projs.count,     fromPlayer,
    }) catch return;
    for (g.projs.items(), 0..) |*pr, pi| {
        if (pi >= 4) break;
        w.print(" a{d}=({d:.1},{d:.1},{d:.1}|{d:.1})", .{ pi, pr.Pos.x, pr.Pos.y, pr.Pos.z, pr.Vel.y }) catch return;
    }
    w.print(" | flash={d:.2} shake={d:.2} gas={d} parts={d} mons={d} wind={d} hp={d:.0} | nan={s}", .{
        g.damageFlash, g.shake, g.gasCount, g.parts.count, g.monsterCount, windups, g.p.HP,
        if (nanLen == 0) "OK" else nanFlags[0..nanLen],
    }) catch return;
    if (anom) {
        w.print(" !!!ANOM med={d:.0} -> {d:.0} png={s}", .{ med, mAvg, anomName }) catch return;
    }
    w.print("\n", .{}) catch return;
    f.writeAll(fbs.getWritten()) catch {};
}

// The main-pass frame setup shared by the game and the editor: open the frame, push the
// torch/fire/fog uniforms, enter 3D, and lay down the static scene (baked mesh, ground,
// walls). Both renderers MUST agree here or the frozen lighting drifts, so it lives once.
// The depth pre-pass differs per renderer and stays at the call site.
pub fn beginSceneFrame(g: *Game, cam: rl.Camera3D, lp: tl.LightParams, fp: tl.FireParams) void {
    rl.beginDrawing();
    rl.clearBackground(theme.voidColor);
    g.torch.applyUniforms(lp);
    g.torch.applyFireUniforms(fp);
    g.torch.applyFogUniforms(.{ .texId = @intCast(g.fog.tex.id), .halfW = g.fog.halfW, .halfD = g.fog.halfD });
    rl.beginMode3D(cam);
    g.torch.beginScene();
    // beginScene left the shadow map active on slot 10; reset to 0 so immediate-mode binds land on slot 0.
    rl.gl.rlActiveTextureSlot(0);
    g.sceneMesh.drawScene(); // includes the floor quad (material field; no drawPlane)
    drawWalls(&g.w);
}

// drawWorld renders one frame of the 3D scene through the frozen torch pipeline.
// ── NPC rendering (town) ─────────────────────────────────────────────────────────
// NPCs are drawn lit in the main scene pass, culled to the torch disc like monsters. They
// carry no combat state — a simple robed humanoid, tinted by kind, with a gentle idle bob.
fn drawNpcs(g: *Game, lightGround: rl.Vector3, radius: f32) void {
    for (g.map.npcList()) |npc| {
        if (dist2XZ(npc.pos(), lightGround) > radius * radius) continue;
        drawNpcBody(g, npc);
    }
}

fn npcColor(k: mapmod.NpcKind) rl.Color {
    return switch (k) {
        .villager => rgba(122, 112, 92, 255),
        .elder => rgba(150, 142, 168, 255),
        .merchant => rgba(156, 124, 72, 255),
        .guard => rgba(92, 104, 126, 255),
        .blacksmith => rgba(98, 82, 74, 255),
        .wizard => rgba(74, 92, 152, 255),
    };
}

pub fn drawNpcBody(g: *Game, npc: mapmod.Npc) void {
    // Flush the batch so a mid-body overflow can't upload a stale matrix to the scene shader
    // (the monster-body lighting hazard). We draw at absolute coords, so identity is correct.
    rl.gl.rlDrawRenderBatchActive();
    const gy = g.w.groundY(npc.x, npc.z);
    const bob = 0.03 * sinf(g.elapsed * 1.6 + npc.x * 0.7 + npc.z * 0.5);
    const base = npcColor(npc.kind);
    const dark = lerpColor(base, rl.Color.black, 0.4);
    const rad: f32 = 0.42;
    const bodyH: f32 = 1.5;
    const fr = mathx.radians(npc.facing);
    const f = v3(-sinf(fr), 0, -cosf(fr)); // 0° faces -Z, matching the hero's default
    // Ground shadow puck.
    rl.drawCylinderEx(v3(npc.x, gy + 0.012, npc.z), v3(npc.x, gy + 0.02, npc.z), rad * 1.15, rad * 1.15, 16, mathx.withAlpha(rl.Color.black, 95));
    // Robe/torso (a capsule) + head; a small nub marks facing for the top-down camera.
    rl.drawCapsule(v3(npc.x, gy + 0.34 + bob, npc.z), v3(npc.x, gy + bodyH + bob, npc.z), rad, 10, 4, base);
    const hy = gy + bodyH + 0.26 + bob;
    sphere(v3(npc.x, hy, npc.z), 0.25, lerpColor(base, rgba(224, 196, 166, 255), 0.55));
    sphere(v3(npc.x + f.x * 0.2, hy, npc.z + f.z * 0.2), 0.07, dark);
}

fn drawWorld(g: *Game) void {
    var cam = g.rig.cam;
    if (g.shake > 0) {
        const amp = g.shake * 0.7;
        cam.position.x += amp * sinf(g.elapsed * 63);
        cam.position.y += amp * cosf(g.elapsed * 71);
    }

    const t = g.elapsed;
    // Torch breathing: the lit disc contracts a few percent on two beats. Downward-only
    // (never past TORCH_RADIUS) so bodies culled at TORCH_RADIUS stay inside the light.
    const breath = 1.0 - 0.022 * (0.5 + 0.5 * sinf(t * 7.1)) - 0.014 * (0.5 + 0.5 * sinf(t * 13.7));
    // The light hangs over the CARRIED flame (g.torchXZ), not the hero's head, so shadows
    // lean off the torch hand. Rides LOCAL ground, so a rampart lifts the whole rig.
    const pGroundY = g.w.groundY(g.p.Pos.x, g.p.Pos.z);
    const lp = tl.LightParams{ .pos = v3(g.torchXZ.x, pGroundY + TORCH_HEIGHT, g.torchXZ.z), .radius = TORCH_RADIUS * breath, .groundRef = pGroundY };
    // Body-draw gates measure from the light's own ground point, so cull set and lit disc can't diverge.
    const lightGround = v3(g.torchXZ.x, 0, g.torchXZ.z);
    const fp = fireLight(g, t);
    // Stash EXACTLY what this frame renders with — debugFrameProbe logs it against the
    // frame's measured pixels after endDrawing, so state and picture can't disagree.
    if (g.debugLog) {
        dbgLp = lp;
        dbgFp = fp;
        dbgCam = cam;
    }
    const ms = g.liveMonsters();
    const drawHero = g.p.alive();

    // --- torch depth pass (obstacle mesh + nearby monsters + player cast) ---
    g.torch.beginShadowPass(lp);
    submitCasters(g, ms, lightGround, lp.radius, fp, drawHero);
    g.torch.endShadowPass();

    // --- fireball depth pass (only when a bolt is live) ---
    if (fp.intensity > 0) {
        g.torch.beginFireShadowPass(fp);
        submitCasters(g, ms, lightGround, lp.radius, fp, drawHero);
        g.torch.endFireShadowPass();
    }

    // --- main pass ---
    beginSceneFrame(g, cam, lp, fp);
    drawMonstersLit(ms, lightGround, lp.radius, fp, g.p.targetMonster);
    drawNpcs(g, lightGround, lp.radius);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endScene();
    if (drawHero) drawHeroFX(&g.p, t);
    drawMonstersFX(ms, lightGround, g.p.Pos, lp.radius, fp, g.p.targetMonster, t);
    drawGasClouds(g, lightGround, lp.radius, fp, t);
    drawLoot(&g.lootList, lightGround, lp.radius, fp);
    drawProjectiles(&g.projs, t);
    drawPortal(&g.w, t);
    drawFireflies(g, t);
    g.parts.draw();
    rl.endMode3D();
}

pub fn run(shot: bool) void {
    // 4x MSAA smooths every polygon edge; set before initWindow or the GL context ignores it.
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_hidden = shot });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    // Esc is NAVIGATION (menus, editor, playtest exit); raylib's default exit key is Esc,
    // which would kill the window. Quitting goes through the menu's Quit item or close button.
    rl.setExitKey(.null);
    // Uncapped: setTargetFPS paces by OS sleep, whose ~15.6ms Windows granularity
    // periodically oversleeps a 60fps target into a dropped frame. Free removes that
    // jitter; to re-cap later prefer .vsync_hint over setTargetFPS.

    var g = Game.init(if (shot) 1234 else mathx.timeSeed()) catch return;
    defer g.deinit();
    defer g.rumble.stop(); // never leave a motor latched on after the window closes

    // Screenshot harness: skip the menu, sweep a few vantages — the rampart, arena
    // center, the spawn grove, and the forced-open portal. Camera snaps to each
    // teleport, then a dozen frames run so fog/particles/rig settle before the shutter.
    const sweep = [_]rl.Vector3{
        mathx.ground(31.5, 20), // atop the Blood Moor rampart (ledge spans x 26.., z 4..30)
        mathx.ground(0, 0),
        mathx.ground(g.map.spawn.x, g.map.spawn.z), // the spawn grove: one tree of each silhouette
        mathx.ground(g.w.PortalPos.x, g.w.PortalPos.z + 5),
    };
    // Which sweep vantage gets the family-portrait staging (arena center). The portal
    // shot is always the last vantage (sweep.len - 1). Named so a reorder is one edit.
    const FAMILY_SHOT = 1;
    if (shot) {
        g.scene = .playing;
        teleportHero(&g, sweep[0]);
        // Drain resources partway so the orbs show a liquid surface (a full orb hides the meniscus).
        g.p.HP = g.p.MaxHP * 0.62;
        g.p.Mana = g.p.MaxMana * 0.45;
        // Rampart tableau: a pack at the cliff base and a firebolt frozen mid-descent.
        g.p.Facing = dirXZ(g.p.Pos, v3(22, 0, 15));
        g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(22.5, 13.5)));
        g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(20.5, 17)));
        g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(23.5, 19)));
        const boltFrom = v3(31.5, 2.4, 20);
        const boltTo = v3(21, 0, 13.5);
        g.projs.add(projectile.newFirebolt(boltFrom, dirXZ(boltFrom, boltTo), stats.Damage.one(.fire, playermod.BASE_SPELL_DMG), 0.9, distXZ(boltFrom, boltTo)));
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
                if (input.navDown()) g.menuSel = navWrap(g.menuSel, 1, n);
                if (input.navUp()) g.menuSel = navWrap(g.menuSel, -1, n);
                if (input.confirm(altHeld)) menuActivate(&g, g.menuSel);
                if (g.menuMode == .options) {
                    if (input.cancel()) {
                        g.menuMode = .root;
                        g.menuSel = MENU_OPTIONS_IDX;
                    }
                    // Left/right cycles the display value on the Display row.
                    if (g.menuSel == @intFromEnum(OptionsItem.display) and (input.navLeft() or input.navRight())) {
                        cycleDisplayMode(&g, input.navRight());
                    }
                }
                g.rig.follow(g.p.Pos, dt); // let the backdrop drift
            },
            .playing => {
                // Character screen (Select / C) freezes the world; it has Stats + Skills
                // pages. K is a keyboard shortcut straight to the Skills page. Both close
                // paths route through closeCharScreen so the loadout persists.
                if (input.sheetTogglePressed() and !g.trig.dialogue.active) {
                    if (g.sheetOpen) g.closeCharScreen() else g.sheetOpen = true;
                }
                if (input.skillsShortcutPressed() and !g.trig.dialogue.active) {
                    if (g.sheetOpen and g.charTab == .skills) g.closeCharScreen() else {
                        g.sheetOpen = true;
                        g.charTab = .skills;
                    }
                }
                if (g.sheetOpen) {
                    updateCharScreen(&g, altHeld);
                    g.rig.follow(g.p.Pos, dt); // keep the camera live behind the screen
                } else {
                    // Exit to menu is Escape/Start ONLY — never pad B (dodge in play). A live
                    // conversation swallows Escape/Start (it closes the box instead — updateDialogue).
                    if ((rl.isKeyPressed(.escape) or input.startPressed()) and !g.trig.dialogue.active) {
                        if (g.playtest) endPlaytest(&g) else {
                            g.scene = .menu;
                            g.hoverMonster = -1; // no hover ring pulsing in the menu backdrop
                        }
                    }
                    if (g.scene == .playing) updatePlaying(&g, dt);
                }
            },
            .dead => {
                if (input.restartPressed(altHeld)) {
                    if (g.playtest) endPlaytest(&g) else g.startRun();
                }
                g.parts.update(dt, &g.w); // let the killing blow's burst finish playing
            },
            .victory => {
                if (input.confirm(altHeld)) g.startRun();
            },
            .editor => editor.update(&g, dt),
        }

        // Drive rumble every frame across all scenes so envelopes always decay to silence.
        // Silent while paused, with no controller, or in the headless screenshot harness.
        g.rumble.update(dt, !shot and rl.isGamepadAvailable(PAD) and !g.paused);

        // Family portrait holds the hero mid-plant (ext=1, ping star) through the settle
        // frames — dt is uncapped, so a one-shot timer could expire before the capture.
        if (shot and shotIdx == FAMILY_SHOT and g.scene == .playing) g.p.swing = playermod.swingDur * 0.55;

        if (g.scene == .editor) {
            editor.draw(&g);
            editor.drawOverlay(&g);
            rl.endDrawing();
        } else {
            drawWorld(&g);
            hudx.draw(&g);
            rl.endDrawing();
            debugFrameProbe(&g); // reads back + measures the frame just presented
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
                    const ei = shotIdx - sweep.len;
                    // First extra shot: the stat sheet over the frozen world, points banked so the "+" shows.
                    if (ei == 0) {
                        g.scene = .playing;
                        g.p.attrPoints = 5;
                        g.p.skillPoints = 1;
                        g.sheetOpen = true;
                        g.charTab = .stats;
                        continue;
                    }
                    // Skills loadout — the button row + skill pool, focus on the button row…
                    if (ei == 1) {
                        g.charTab = .skills;
                        g.skillZone = .slots;
                        g.skillSel = 0;
                        continue;
                    }
                    // …then with the cursor down in the pool, so the pool-focus styling shows.
                    if (ei == 2) {
                        g.charTab = .skills;
                        g.skillZone = .pool;
                        g.skillPoolSel = 3; // Firebolt — a bound chip, so its badge shows
                        continue;
                    }
                    g.sheetOpen = false; // close it before the full-screen scene shots
                    // Then each full-screen scene (editor last, entered properly so it loads + applies).
                    const extraScenes = [_]Scene{ .menu, .dead, .victory, .editor };
                    const si = ei - 3;
                    if (si >= extraScenes.len) break;
                    if (extraScenes[si] == .editor) {
                        g.areaIndex = 0;
                        editor.enter(&g);
                    } else {
                        g.scene = extraScenes[si];
                    }
                    continue;
                }
                teleportHero(&g, sweep[shotIdx]);
                g.p.swing = 0; // a posed/live swing never bleeds into the next vantage
                g.banner.time = 0; // the area banner would sit right over the subjects
                if (shotIdx == FAMILY_SHOT) {
                    // Family portrait: one of each kind around the hero, three-quarter and zoomed — verifies every silhouette.
                    const px = g.p.Pos.x;
                    const pz = g.p.Pos.z;
                    const posedBase = g.monsterCount; // capture before the four spawns — index off this, never count-4 (usize underflow if a spawn were dropped)
                    g.spawn(monster.makeMonster(.fallen, 0, &g.rng, mathx.ground(px - 3, pz - 1)));
                    g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(px + 3, pz - 1.5)));
                    g.spawn(monster.makeMonster(.skeleton, 0, &g.rng, mathx.ground(px - 1, pz - 4)));
                    g.spawn(monster.makeMonster(.brute, 0, &g.rng, mathx.ground(px + 2.5, pz + 3)));
                    var mi = posedBase;
                    while (mi < g.monsterCount) : (mi += 1) {
                        g.monsters[mi].Facing = v3(-0.66, 0, 0.75);
                    }
                    // Pib mid-SWING so the arc shows (blade crossing, flare + trail). Posed
                    // dummies get STRETCHED timers: settle frames still tick updateMonster,
                    // and a real-length swing would decay past its readable middle.
                    g.monsters[posedBase].swingTime = 3.0;
                    g.monsters[posedBase].swing = 1.5;
                    // Zombie near the top of its raise: both claws overhead, body reared — full slam telegraph.
                    g.monsters[posedBase + 1].windupTime = 6.0;
                    g.monsters[posedBase + 1].windup = 0.9;
                    // Skeleton mid-draw: string back, arrow nocked, head glinting — aimed at
                    // the hero (windup AI keeps facing through the settle frames).
                    g.monsters[posedBase + 2].windupTime = 6.0;
                    g.monsters[posedBase + 2].windup = 2.4;
                    // Engage the brute so the top-center enemy plate is in frame (hover re-derives,
                    // but the attack target sticks and the plate reads from it).
                    g.p.targetMonster = g.monsters[posedBase + 3].id;
                    // Hero mid-thrust at the engaged brute (facing auto-tracks the target).
                    // swingDur is a const, so the timer can't be stretched like the posed
                    // monsters' — it gets re-pinned every settle frame instead.
                    g.p.swingKind = .thrust;
                    // Brute part-way into its heavy-stun meter to verify the amber stun channel under the HP bar.
                    g.monsters[posedBase + 3].stunFill = 0.6;
                    // And one fresh corpse mid-fade, to verify the spreading blood pool.
                    g.spawn(monster.makeMonster(.zombie, 0, &g.rng, mathx.ground(px + 0.6, pz + 4.6)));
                    g.monsters[g.monsterCount - 1].dying = true;
                    g.monsters[g.monsterCount - 1].HP = 0;
                    g.monsters[g.monsterCount - 1].deathTimer = monster.monster_death_fade * 0.5;
                    // Miasma already billowed out (aged past grow-in to verify the full cloud).
                    spawnGasCloud(&g, g.monsters[g.monsterCount - 1].Pos, g.monsters[g.monsterCount - 1].MaxDmg * GAS_DPS_FRAC);
                    if (g.gasCount > 0) g.gas[g.gasCount - 1].life = GAS_LIFE - 1.5;
                    // A firebolt frozen mid-flight, to verify the bolt + its trail (aimed
                    // at its own muzzle height = level drift for the still).
                    const bp = mathx.ground(px - 1.5, pz + 2.5);
                    g.projs.add(projectile.newFirebolt(bp, v3(-0.8, 0, 0.6), stats.Damage.one(.fire, playermod.BASE_SPELL_DMG), bp.y + projectile.fireboltMuzzleDY, 10));
                    // Ground loot just out of pickup range, to verify the drop beams.
                    g.lootList.append(.{ .Kind = .gold, .Pos = mathx.ground(px - 0.4, pz + 4.0), .Amount = 25 }) catch {};
                    g.lootList.append(.{ .Kind = .health_potion, .Pos = mathx.ground(px - 2.6, pz + 2.0), .Amount = 1 }) catch {};
                    g.rig.zoom = 2.2;
                    g.rig.snap(g.p.Pos);
                }
                if (shotIdx == sweep.len - 1) {
                    g.rig.zoom = cameramod.DEFAULT_ZOOM;
                    g.rig.snap(g.p.Pos);
                    g.w.PortalOpen = true; // show the vortex...
                    // ...and clear the stage: anything camped on the portal hides it.
                    g.monsterCount = retain(Monster, g.liveMonsters(), g.w.PortalPos, struct {
                        fn keep(portal: rl.Vector3, m2: *Monster) bool {
                            return distXZ(m2.Pos, portal) > 12;
                        }
                    }.keep);
                }
            }
        }
    }
}
