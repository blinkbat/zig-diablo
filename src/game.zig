const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const tl = @import("torchlight.zig");
const world = @import("world.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
const scenemesh = @import("scenemesh.zig");
const fogmod = @import("fog.zig");
const playermod = @import("player.zig");
const loot = @import("loot.zig");
const cameramod = @import("camera.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");
const rumble = @import("rumble.zig");

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

// Torch tuning: fixed at the frozen demo defaults now that the wheel drives camera
// zoom and Q/E are gone. The torch sits straight above the hero (point light).
const TORCH_HEIGHT = 6.0;
const TORCH_RADIUS = 12.0;
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

// Floating combat text: the inline buffer capacity (shared by the Popup store, the
// formatter, and the HUD that renders it) and the default lift above an entity's
// ground position so numbers float over the body rather than at its feet.
pub const POPUP_TEXT_CAP = 32;
const POPUP_HEIGHT = 1.6;

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

// Popup is floating combat text anchored in the world. Its text lives inline in a
// fixed buffer so the popup is self-contained inside the ArrayList (no dangling slice).
pub const Popup = struct {
    Pos: rl.Vector3 = mathx.zero3,
    text_buf: [POPUP_TEXT_CAP]u8 = undefined,
    text_len: usize = 0,
    Color: rl.Color = rgba(255, 255, 255, 255),
    Life: f32 = 0,
    maxLife: f32 = 0,

    pub fn text(self: *const Popup) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const Scene = enum { menu, playing, dead, victory };

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

// Low-poly sphere. raylib's drawSphere defaults to 16x16 and regenerates on the CPU
// with per-vertex trig on every call — the scene is drawn twice a frame (shadow depth
// pass + main pass). Under a dark torch an 8x8 ball is indistinguishable at ~1/4 cost.
fn sphere(pos: rl.Vector3, r: f32, col: rl.Color) void {
    rl.drawSphereEx(pos, r, 8, 8, col);
}

// ---- Game state ----

pub const Game = struct {
    scene: Scene = .menu,
    rng: mathx.Rng,
    torch: tl.Torch,
    sceneMesh: scenemesh.SceneMesh,
    fog: fogmod.Fog,
    w: world.World,
    areaIndex: usize = 0,
    lastArea: usize,

    p: Player,
    monsters: [MAX_MONSTERS]Monster = undefined,
    monsterCount: usize = 0,
    nextID: i32 = 0,
    projs: ProjList = .{},
    lootList: std.ArrayList(LootDrop),
    popups: std.ArrayList(Popup),

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

    pub fn init(seed: u64) !Game {
        var torch = try tl.Torch.init();
        errdefer torch.deinit();
        var rng = mathx.Rng.init(seed);
        const lastArea = world.areas.len - 1;
        const w = world.buildWorld(world.areas[0], &rng, lastArea == 0);
        const sceneMesh = scenemesh.SceneMesh.init(&w, torch.scene, torch.depthShader);
        var fog = fogmod.Fog.init();
        fog.reset(w.Half);

        var g = Game{
            .rng = rng,
            .torch = torch,
            .sceneMesh = sceneMesh,
            .fog = fog,
            .w = w,
            .lastArea = lastArea,
            .p = playermod.newPlayer(world.startPos(w)),
            .lootList = std.ArrayList(LootDrop).init(alloc),
            .popups = std.ArrayList(Popup).init(alloc),
            .rig = cameramod.newCamRig(),
        };
        g.areaIndex = 0;
        g.spawnPacks();
        g.rig.snap(g.p.Pos);
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.w.Name});
        return g;
    }

    pub fn deinit(g: *Game) void {
        g.sceneMesh.deinit();
        g.fog.deinit();
        g.torch.deinit();
        g.lootList.deinit();
        g.popups.deinit();
    }

    // startRun resets a finished/dead game back to area 0 with a fresh hero.
    pub fn startRun(g: *Game) void {
        g.p = playermod.newPlayer(mathx.zero3);
        g.kills = 0;
        g.elapsed = 0;
        g.enterArea(0);
        g.scene = .playing;
    }

    // enterArea (re)builds the world for the given area index and spawns packs.
    pub fn enterArea(g: *Game, idx: usize) void {
        g.areaIndex = if (idx > g.lastArea) g.lastArea else idx;
        g.w = world.buildWorld(world.areas[g.areaIndex], &g.rng, g.areaIndex == g.lastArea);
        g.sceneMesh.rebuild(&g.w);
        g.fog.reset(g.w.Half); // each area is a fresh layout: forget the old exploration
        g.fog.sync(); // upload the cleared grid now: a restart from dead/victory draws
        // this frame WITHOUT running updatePlaying, so it would otherwise render the new
        // area against the previous area's still-resident fog mask for one frame.
        g.monsterCount = 0;
        g.projs.count = 0;
        g.lootList.clearRetainingCapacity();
        g.popups.clearRetainingCapacity();
        g.spawnPacks();
        g.p.Pos = world.startPos(g.w);
        g.p.hasMoveTarget = false;
        g.p.targetMonster = -1;
        g.p.HP = g.p.MaxHP;
        g.p.Mana = g.p.MaxMana;
        g.rig.snap(g.p.Pos);
        g.setBanner(AREA_BANNER_DUR, "{s}", .{g.w.Name});
        g.setToast("", .{});
    }

    // spawnPacks scatters monster groups across the arena, plus one boss near the portal.
    fn spawnPacks(g: *Game) void {
        const def = world.areas[g.areaIndex];
        const spawnPos = world.startPos(g.w);
        var pack: i32 = 0;
        while (pack < def.packs) : (pack += 1) {
            const center = g.randomOpenTile(spawnPos, 16);
            const packSize = 2 + g.rng.intn(3);
            const kind = def.kinds[@intCast(g.rng.intn(@intCast(def.kinds.len)))];
            var i: i32 = 0;
            while (i < packSize) : (i += 1) {
                g.spawn(monster.makeMonster(kind, def.tier, &g.rng, g.randomOpenTileNear(center, 5)));
            }
        }
        g.spawn(monster.makeBoss(def.tier, def.boss, &g.rng, g.randomOpenTileNear(g.w.PortalPos, 8)));
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

    fn randomOpenTile(g: *Game, from: rl.Vector3, minFrom: f32) rl.Vector3 {
        const h = g.w.Half - 3;
        var attempt: i32 = 0;
        while (attempt < 60) : (attempt += 1) {
            const p = mathx.ground((g.rng.float() * 2 - 1) * h, (g.rng.float() * 2 - 1) * h);
            if (distXZ(p, from) < minFrom) continue;
            if (!g.w.blocked(p, 1.0)) return p;
        }
        return mathx.ground(0, 0);
    }

    fn randomOpenTileNear(g: *Game, center: rl.Vector3, spread: f32) rl.Vector3 {
        var attempt: i32 = 0;
        while (attempt < 40) : (attempt += 1) {
            const p = mathx.ground(center.x + (g.rng.float() * 2 - 1) * spread, center.z + (g.rng.float() * 2 - 1) * spread);
            if (!g.w.blocked(p, 0.8)) return p;
        }
        return center;
    }

    // inVision: within the torch's lit disc. Beyond it the world is black, so the hero
    // can't target, and health bars / popups there would float in darkness.
    pub fn inVision(g: *const Game, p: rl.Vector3) bool {
        return distXZ(p, g.p.Pos) <= CULL;
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

    pub fn addPopup(g: *Game, pos: rl.Vector3, txt: []const u8, col: rl.Color) void {
        var pp = Popup{ .Pos = pos, .Color = col, .Life = 1.0, .maxLife = 1.0 };
        const n = @min(txt.len, pp.text_buf.len);
        @memcpy(pp.text_buf[0..n], txt[0..n]);
        pp.text_len = n;
        g.popups.append(pp) catch @panic("oom");
    }

    // Format a floating combat-text popup in one step (damage/XP/gold numbers all
    // share this instead of each hand-rolling a stack buffer + bufPrint).
    pub fn addPopupFmt(g: *Game, pos: rl.Vector3, col: rl.Color, comptime fmt: []const u8, args: anytype) void {
        var buf: [POPUP_TEXT_CAP]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        g.addPopup(pos, txt, col);
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
    updatePopups(g, dt);
    updateDeaths(g, dt);
    updatePortal(g);

    g.rig.follow(g.p.Pos, dt);

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
    g.projs.add(projectile.newFirebolt(p.Pos, dir, dmg));
    g.rumble.play(rumble.cast);
}

// Attempt a dodge roll in dir, playing the shared feedback (rumble + popup) on
// success. The keyboard and gamepad paths only differ in how they pick dir, so the
// roll + feedback lives here once.
fn doDodge(g: *Game, dir: rl.Vector3) void {
    if (g.p.startRoll(dir)) {
        g.rumble.play(rumble.dodge);
        g.addPopup(v3(g.p.Pos.x, 2.1, g.p.Pos.z), "Dodge!", rgba(180, 220, 255, 255));
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
    if (mathx.rayGround(ray)) |pt| g.mouseGround = pt;

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
    if (distXZ(p.Pos, m.Pos) <= playerReach(p.atkRange, m.Radius)) {
        var dmg = p.MinDmg + g.rng.float() * (p.MaxDmg - p.MinDmg);
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
    const col = if (crit) rgba(255, 220, 60, 255) else rl.Color.white;
    const di: i32 = @intFromFloat(dmg);
    const pp = v3(m.Pos.x, m.Pos.y + POPUP_HEIGHT, m.Pos.z);
    if (crit) g.addPopupFmt(pp, col, "{d}!", .{di}) else g.addPopupFmt(pp, col, "{d}", .{di});
    if (m.HP <= 0 and !m.dying) killMonster(g, m);
}

fn killMonster(g: *Game, m: *Monster) void {
    m.HP = 0;
    m.dying = true;
    m.deathTimer = monster.monster_death_fade;
    g.kills += 1;
    g.rumble.play(rumble.kill);
    if (g.p.addXP(m.XP)) onLevelUp(g);
    g.addPopupFmt(v3(m.Pos.x, m.Pos.y + POPUP_HEIGHT, m.Pos.z), rgba(120, 200, 255, 255), "+{d} XP", .{m.XP});
    loot.rollLoot(m, &g.rng, &g.lootList);
    if (m.boss) g.setToast("{s} has been slain!", .{m.Name});
    if (g.p.targetMonster == m.id) g.p.targetMonster = -1;
}

fn onLevelUp(g: *Game) void {
    g.setBanner(LEVELUP_BANNER_DUR, "Level {d}!", .{g.p.Level});
    g.rumble.play(rumble.level_up);
    g.shake = maxF(g.shake, 0.3);
    g.addPopup(v3(g.p.Pos.x, 2.2, g.p.Pos.z), "LEVEL UP", rgba(255, 230, 120, 255));
}

// ---- Monster AI ----

fn moveMonster(g: *Game, m: *Monster, dir: rl.Vector3, dt: f32) void {
    if (lenXZ(dir) < 1e-4) return;
    m.Pos = g.w.moveWithCollision(m.Pos, v3(dir.x * m.Speed * dt, 0, dir.z * m.Speed * dt), m.Radius);
}

fn updateMonster(g: *Game, m: *Monster, dt: f32) void {
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
            moveMonster(g, m, dirXZ(m.Pos, g.p.Pos), dt);
        } else if (toPlayer < m.atkRange * 0.35) {
            moveMonster(g, m, dirXZ(g.p.Pos, m.Pos), dt * 0.7);
        }
        if (toPlayer <= m.atkRange and m.atkCD <= 0) m.windup = m.windupTime;
        return;
    }

    // Melee: close the gap, then commit to a telegraphed swing.
    if (toPlayer > m.atkRange + g.p.Radius) {
        moveMonster(g, m, dirXZ(m.Pos, g.p.Pos), dt);
    } else if (m.atkCD <= 0) {
        m.windup = m.windupTime;
    }
}

fn resolveMonsterAttack(g: *Game, m: *Monster) void {
    if (!g.p.alive()) return;
    const dmg = m.MinDmg + g.rng.float() * (m.MaxDmg - m.MinDmg);
    if (m.Ranged) {
        g.projs.add(projectile.newArrow(m.Pos, dirXZ(m.Pos, g.p.Pos), dmg));
        return;
    }
    // Use the module radius constant — the SAME source the drawn telegraph ring reads
    // (drawMonstersFX) — so standing just outside the red ring is genuinely safe.
    if (distXZ(m.Pos, g.p.Pos) <= meleeReach(m.atkRange, playermod.radius)) hitPlayer(g, dmg);
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
        g.addPopup(v3(g.p.Pos.x, 2.0, g.p.Pos.z), "dodged", rgba(180, 220, 255, 230));
        return;
    }
    g.p.takeDamage(dmg);
    g.damageFlash = DAMAGE_FLASH_DUR;
    g.shake = maxF(g.shake, 0.25);
    g.rumble.play(rumble.hurt);
    const di: i32 = @intFromFloat(dmg);
    g.addPopupFmt(v3(g.p.Pos.x, 2.0, g.p.Pos.z), rgba(255, 90, 90, 255), "-{d}", .{di});
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
    pr.Pos.z += pr.Vel.z * c.dt;
    pr.Life -= c.dt;
    if (pr.Life <= 0 or g.w.rayHitsObstacle(pr.Pos, pr.Radius)) return false;
    if (pr.FromPlayer) {
        for (g.liveMonsters()) |*m| {
            if (m.alive() and distXZ(m.Pos, pr.Pos) < m.Radius + pr.Radius) {
                damageMonster(g, m, pr.Damage, false);
                return false;
            }
        }
    } else if (g.p.alive() and distXZ(g.p.Pos, pr.Pos) < g.p.Radius + pr.Radius) {
        hitPlayer(g, pr.Damage);
        return false;
    }
    return true;
}
fn updateProjectiles(g: *Game, dt: f32) void {
    g.projs.count = retain(Projectile, g.projs.items(), SweepCtx{ .g = g, .dt = dt }, keepProjectile);
}

// Loot: bob in place; collected (and dropped) when the player walks over it.
fn keepLoot(c: SweepCtx, d: *LootDrop) bool {
    d.bob += c.dt * 3;
    if (distXZ(d.Pos, c.g.p.Pos) < c.g.p.Radius + 1.3) {
        collect(c.g, d.*);
        return false;
    }
    return true;
}
fn updateLoot(g: *Game, dt: f32) void {
    const n = retain(LootDrop, g.lootList.items, SweepCtx{ .g = g, .dt = dt }, keepLoot);
    g.lootList.shrinkRetainingCapacity(n);
}

fn collect(g: *Game, d: LootDrop) void {
    switch (d.Kind) {
        .gold => {
            g.p.Gold += d.Amount;
            g.addPopupFmt(v3(g.p.Pos.x, g.p.Pos.y + POPUP_HEIGHT, g.p.Pos.z), theme.goldColor, "+{d}g", .{d.Amount});
        },
        .health_potion => {
            if (g.p.HealthPots < playermod.maxPots) g.p.HealthPots += 1;
            g.setToast("Picked up a Health Potion", .{});
        },
        .mana_potion => {
            if (g.p.ManaPots < playermod.maxPots) g.p.ManaPots += 1;
            g.setToast("Picked up a Mana Potion", .{});
        },
    }
}

fn keepPopup(c: SweepCtx, pp: *Popup) bool {
    pp.Life -= c.dt;
    pp.Pos.y += c.dt * 1.4;
    return pp.Life > 0;
}
fn updatePopups(g: *Game, dt: f32) void {
    const n = retain(Popup, g.popups.items, SweepCtx{ .g = g, .dt = dt }, keepPopup);
    g.popups.shrinkRetainingCapacity(n);
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

fn updatePortal(g: *Game) void {
    if (!g.w.PortalOpen and g.remainingMonsters() == 0) {
        g.w.PortalOpen = true;
        g.setToast("Area cleared - a portal has opened!", .{});
    }
    if (g.w.PortalOpen and distXZ(g.p.Pos, g.w.PortalPos) < 2.4) {
        if (g.w.IsLast) {
            g.scene = .victory;
        } else {
            g.enterArea(g.areaIndex + 1);
        }
    }
}

// ---- Rendering (frozen torchlight + baked scene mesh) ----

// The hero: a cloaked, hooded ranger. Plain tint — torchlight shades + shadows it.
fn drawHeroBody(p: *const Player) void {
    const base = p.Pos;
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
    rl.drawCapsule(v3(base.x, 0.5 + bob, base.z), v3(base.x, 1.42 + bob, base.z), 0.42, 12, 8, cloak);
    rl.drawCapsule(v3(base.x - f.x * 0.22, 0.55 + bob, base.z - f.z * 0.22), v3(base.x - f.x * 0.12, 1.25 + bob, base.z - f.z * 0.12), 0.3, 10, 6, lerpColor(cloak, rl.Color.black, 0.25));

    sphere(v3(base.x, 1.72 + bob, base.z), 0.34, hood);
    sphere(v3(base.x + f.x * 0.22, 1.70 + bob, base.z + f.z * 0.22), 0.2, lerpColor(skin, rl.Color.black, 0.35));
    rl.drawCylinderEx(v3(base.x - f.x * 0.1, 1.9 + bob, base.z - f.z * 0.1), v3(base.x - f.x * 0.3, 2.18 + bob, base.z - f.z * 0.3), 0.18, 0.02, 6, hood);

    const bowCol = rgba(96, 66, 38, 255);
    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15 + bob, base.z - f.z * 0.18 + right.z * 0.4);
    rl.drawCylinderEx(bhand, v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18), 0.07, 0.03, 5, bowCol);
    rl.drawCylinderEx(bhand, v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18), 0.07, 0.03, 5, bowCol);

    const thand = v3(base.x - right.x * 0.45 + f.x * 0.05, 0.95, base.z - right.z * 0.45 + f.z * 0.05);
    rl.drawCylinderEx(thand, v3(thand.x, thand.y + 0.55, thand.z), 0.05, 0.04, 5, rgba(70, 48, 30, 255));
}

// Emissive hero bits (no shadow): bowstring, melee swing arc, the torch flame + embers.
fn drawHeroFX(p: *const Player, t: f32) void {
    const base = p.Pos;
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

    const flick = 1 + 0.18 * sinf(t * 22) + 0.1 * sinf(t * 37);
    const thand = v3(base.x - right.x * 0.45 + f.x * 0.05, 0.95, base.z - right.z * 0.45 + f.z * 0.05);
    const flame = v3(thand.x, thand.y + 0.69, thand.z);
    sphere(flame, 0.26 * flick, rgba(230, 90, 25, 110));
    sphere(flame, 0.17 * flick, rgba(255, 150, 40, 200));
    sphere(flame, 0.09 * flick, rgba(255, 235, 150, 255));
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const ph = @mod(t * 0.8 + iff * 0.37, 1.0);
        const drift = 0.14 * sinf(t * 3 + iff);
        const ep = v3(flame.x + drift, flame.y + ph * 0.9, flame.z + drift * 0.5);
        sphere(ep, 0.045 * (1 - ph), rgba(255, 160, 60, mathx.u8f((1 - ph) * 170)));
    }

    rl.drawCircle3D(v3(base.x, 0.045, base.z), p.Radius + 0.15, v3(1, 0, 0), 90, rgba(150, 190, 255, 90));
}

fn drawWalls(w: *const world.World) void {
    const h = w.Half;
    const wallH = 4.0;
    const t = 1.2;
    const col = w.Accent;
    const segs = [_]rl.Vector3{
        v3(0, wallH / 2, -h), v3(0, wallH / 2, h),
        v3(-h, wallH / 2, 0), v3(h, wallH / 2, 0),
    };
    const sizes = [_]rl.Vector3{
        v3(h * 2 + t, wallH, t), v3(h * 2 + t, wallH, t),
        v3(t, wallH, h * 2 + t), v3(t, wallH, h * 2 + t),
    };
    for (segs, sizes) |seg, size| rl.drawCubeV(seg, size, col);
}

const MONSTER_BOB_AMP = 0.05;
const MONSTER_TORSO_BASE = 0.4;
const MONSTER_HEAD_GAP = 0.25;

fn monsterBob(m: *const Monster) f32 {
    return MONSTER_BOB_AMP * sinf(m.bob);
}
fn monsterHeadY(m: *const Monster, shrink: f32) f32 {
    return MONSTER_TORSO_BASE + (m.Height - 0.5) * shrink + MONSTER_HEAD_GAP * shrink + monsterBob(m);
}

fn drawMonsterBody(m: *const Monster) void {
    const bob = monsterBob(m);
    var col = m.Color;
    var shrink: f32 = 1;
    if (m.dying) {
        shrink = clampF(m.deathTimer / monster.monster_death_fade, 0.12, 1);
    } else if (m.hitFlash > 0) {
        col = lerpColor(col, rl.Color.white, 0.75);
    } else if (m.windup > 0) {
        col = lerpColor(col, rgba(255, 80, 40, 255), 0.35 + 0.45 * (1 - m.windup / m.windupTime));
    }
    const htop = (m.Height - 0.5) * shrink;
    rl.drawCapsule(v3(m.Pos.x, MONSTER_TORSO_BASE + bob, m.Pos.z), v3(m.Pos.x, MONSTER_TORSO_BASE + htop + bob, m.Pos.z), m.Radius, 8, 4, col);
    sphere(v3(m.Pos.x, monsterHeadY(m, shrink), m.Pos.z), m.Radius * 0.7 * shrink, col);
}

// A dynamic body is worth drawing when it sits inside the torch's lit disc, or when a
// live fireball is flying past close enough to light it out in the dark. Gated at the
// torch radius (not the padded CULL) so bodies never linger as dim silhouettes on
// explored-but-dark ground: fog of war shows terrain memory in the "seen" band, never
// monsters or loot. The static scene mesh, by contrast, is always drawn in full.
fn bodyVisible(pos: rl.Vector3, player: rl.Vector3, fp: tl.FireParams) bool {
    if (distXZ(pos, player) <= TORCH_RADIUS) return true;
    return fp.intensity > 0 and distXZ(pos, fp.pos) <= fp.radius;
}

// Depth pass: living bodies visible this frame cast. Bodies neither near the player
// nor lit by the fireball render black anyway, so there's no point shadowing them.
fn drawMonstersCast(ms: []const Monster, player: rl.Vector3, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (m.dying) continue;
        if (!bodyVisible(m.Pos, player, fp)) continue;
        drawMonsterBody(m);
    }
}

fn drawMonstersLit(ms: []const Monster, player: rl.Vector3, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (!bodyVisible(m.Pos, player, fp)) continue;
        drawMonsterBody(m);
    }
}

// Emissive pass (no shadow): glowing eyes + the red attack telegraph + boss ring.
fn drawMonstersFX(ms: []const Monster, player: rl.Vector3, fp: tl.FireParams) void {
    for (ms) |*m| {
        if (m.dying or !m.alive()) continue;
        if (!bodyVisible(m.Pos, player, fp)) continue;
        if (m.boss) {
            rl.drawCircle3D(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.4, v3(1, 0, 0), 90, rgba(255, 60, 60, 200));
        }
        if (m.windup > 0) {
            const tp = 1 - m.windup / m.windupTime;
            const a = mathx.u8f(clampF(110 + 130 * tp, 0, 255));
            if (m.Ranged) {
                rl.drawCylinderEx(v3(m.Pos.x, 1.2, m.Pos.z), v3(player.x, 0.3, player.z), 0.05, 0.05, 4, rgba(255, 70, 50, a));
            } else {
                const rr = meleeReach(m.atkRange, playermod.radius);
                rl.drawCircle3D(v3(m.Pos.x, 0.09, m.Pos.z), rr, v3(1, 0, 0), 90, rgba(255, 60, 40, a));
                rl.drawCircle3D(v3(m.Pos.x, 0.09, m.Pos.z), rr * tp, v3(1, 0, 0), 90, rgba(255, 100, 50, a));
            }
        }
        const headY = monsterHeadY(m, 1);
        const f = mathx.orFacing(m.Facing, 0, 1);
        const right = mathx.perpXZ(f);
        const eyeCol = if (m.windup > 0) rgba(255, 70, 40, 255) else rgba(255, 210, 60, 255);
        for ([_]f32{ -1, 1 }) |s| {
            const e = v3(m.Pos.x + f.x * m.Radius * 0.5 + right.x * m.Radius * 0.3 * s, headY + 0.02, m.Pos.z + f.z * m.Radius * 0.5 + right.z * m.Radius * 0.3 * s);
            sphere(e, 0.07, eyeCol);
        }
    }
}

// Pick the fireball that lights the scene: the first live player bolt. Its light is
// modeled overhead (FIRE_HEIGHT) so the downward shadow map is well-oriented, with a
// warm colour and a gentle flame flicker. intensity 0 => no fireball, light disabled.
fn fireLight(projs: *ProjList, t: f32) tl.FireParams {
    for (projs.items()) |*pr| {
        if (!pr.FromPlayer) continue;
        const flicker = 0.85 + 0.15 * sinf(t * 27);
        return .{
            .pos = v3(pr.Pos.x, FIRE_HEIGHT, pr.Pos.z),
            .radius = FIRE_RADIUS,
            .color = v3(1.0, 0.55, 0.22),
            .intensity = 1.7 * flicker,
        };
    }
    return .{ .pos = mathx.zero3, .radius = FIRE_RADIUS, .color = mathx.zero3, .intensity = 0 };
}

fn drawProjectiles(projs: *ProjList) void {
    for (projs.items()) |*pr| {
        sphere(pr.Pos, pr.Radius, pr.Color);
        const tail = v3(pr.Pos.x - pr.Vel.x * 0.03, pr.Pos.y, pr.Pos.z - pr.Vel.z * 0.03);
        rl.drawCylinderEx(tail, pr.Pos, pr.Radius * 0.3, pr.Radius, 6, mathx.withAlpha(pr.Color, 130));
    }
}

fn drawLoot(lootList: *std.ArrayList(LootDrop), player: rl.Vector3, fp: tl.FireParams) void {
    for (lootList.items) |*d| {
        if (!bodyVisible(d.Pos, player, fp)) continue;
        const y = 0.4 + 0.12 * sinf(d.bob);
        switch (d.Kind) {
            .gold => sphere(v3(d.Pos.x, y * 0.6, d.Pos.z), 0.26, theme.goldColor),
            .health_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), theme.healthColor),
            .mana_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), theme.manaColor),
        }
    }
}

fn drawPortal(w: *const world.World, t: f32) void {
    const pp = w.PortalPos;
    if (!w.PortalOpen) {
        rl.drawCylinderEx(v3(pp.x, 0.02, pp.z), v3(pp.x, 0.05, pp.z), 2.0, 2.0, 24, rgba(60, 60, 80, 200));
        return;
    }
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const yy = iff * 0.7;
        const r = 1.7 - iff * 0.16 + 0.15 * sinf(t * 3 + iff);
        const c = lerpColor(rgba(90, 120, 255, 210), rgba(190, 120, 255, 170), iff / 6);
        rl.drawCylinderEx(v3(pp.x, yy, pp.z), v3(pp.x, yy + 0.7, pp.z), r, r * 0.8, 22, c);
    }
}

// drawWorld renders one frame of the 3D scene through the frozen torch pipeline.
fn drawWorld(g: *Game) rl.Camera3D {
    var cam = g.rig.cam;
    if (g.shake > 0) {
        const amp = g.shake * 0.7;
        cam.position.x += amp * sinf(g.elapsed * 63);
        cam.position.y += amp * cosf(g.elapsed * 71);
    }

    const t = g.elapsed;
    const lp = tl.LightParams{ .pos = v3(g.p.Pos.x, TORCH_HEIGHT, g.p.Pos.z), .radius = TORCH_RADIUS };
    const fp = fireLight(&g.projs, t);
    const ms = g.liveMonsters();
    const drawHero = g.p.alive();

    // --- torch depth pass (obstacle mesh + nearby monsters + player cast) ---
    g.torch.beginShadowPass(lp);
    g.sceneMesh.drawDepth();
    drawMonstersCast(ms, g.p.Pos, fp);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endShadowPass();

    // --- fireball depth pass (only when a bolt is live) ---
    if (fp.intensity > 0) {
        g.torch.beginFireShadowPass(fp);
        g.sceneMesh.drawDepth();
        drawMonstersCast(ms, g.p.Pos, fp);
        if (drawHero) drawHeroBody(&g.p);
        g.torch.endFireShadowPass();
    }

    // --- main pass ---
    rl.beginDrawing();
    rl.clearBackground(rgba(16, 16, 22, 255));
    g.torch.applyUniforms(cam, lp);
    g.torch.applyFireUniforms(fp);
    g.torch.applyFogUniforms(.{ .texId = @intCast(g.fog.tex.id), .half = g.fog.half });
    rl.beginMode3D(cam);
    g.torch.beginScene();
    // beginScene bound the shadow map on slot 10 and left it active; reset to 0 so
    // immediate-mode texture0 binds land on slot 0, not on the shadow map.
    rl.gl.rlActiveTextureSlot(0);
    g.sceneMesh.drawScene();
    rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(g.w.Half * 2, g.w.Half * 2), g.w.Ground);
    drawWalls(&g.w);
    drawMonstersLit(ms, g.p.Pos, fp);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endScene();
    if (drawHero) drawHeroFX(&g.p, t);
    drawMonstersFX(ms, g.p.Pos, fp);
    drawLoot(&g.lootList, g.p.Pos, fp);
    drawProjectiles(&g.projs);
    drawPortal(&g.w, t);
    rl.endMode3D();
    return cam;
}

pub fn run(shot: bool) void {
    // 4x MSAA smooths every polygon edge in the scene (the biggest overall-fidelity
    // win); set before initWindow or the GL context ignores it.
    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_hidden = shot });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    // Uncapped: no setTargetFPS. setTargetFPS paces by OS sleep, whose ~15.6ms Windows
    // timer granularity makes a 60fps target periodically oversleep into a dropped frame
    // (a "chug" despite ample headroom). Running free removes that jitter. To re-cap
    // smoothly later, prefer .vsync_hint (GPU flip pacing) over setTargetFPS.

    var g = Game.init(if (shot) 1234 else mathx.timeSeed()) catch return;
    defer g.deinit();
    defer g.rumble.stop(); // never leave a motor latched on after the window closes

    // Screenshot harness: skip the menu, sweep a couple of vantage points.
    const sweep = [_]rl.Vector3{ world.startPos(g.w), mathx.ground(0, 0) };
    if (shot) {
        g.scene = .playing;
        g.p.Pos = sweep[0];
    }
    var frame: i32 = 0;
    var shotIdx: usize = 0;

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        g.elapsed += dt; // advances in every scene (drives flicker/animation)

        switch (g.scene) {
            .menu => {
                if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space) or padStartPressed()) g.startRun();
                g.rig.follow(g.p.Pos, dt); // let the backdrop drift
            },
            .playing => {
                if (rl.isKeyPressed(.escape) or padStartPressed()) g.scene = .menu;
                updatePlaying(&g, dt);
            },
            .dead => {
                if (rl.isKeyPressed(.r) or padStartPressed()) g.startRun();
            },
            .victory => {
                if (rl.isKeyPressed(.enter) or padStartPressed()) g.startRun();
            },
        }

        // Drive rumble every frame across all scenes so envelopes always decay to
        // silence (the death rumble swells on into the death screen). Silent while
        // paused or with no controller; still ticks so it fades in the background.
        g.rumble.update(dt, rl.isGamepadAvailable(PAD) and !g.paused);

        const cam = drawWorld(&g);
        hudx.draw(&g, cam);
        rl.endDrawing();

        if (shot) {
            frame += 1;
            if (frame >= 3) {
                frame = 0;
                std.fs.cwd().makePath("shots") catch {};
                var buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&buf, "shots/shot_game_{d}.png", .{shotIdx + 1}) catch break;
                rl.takeScreenshot(name);
                shotIdx += 1;
                if (shotIdx >= sweep.len) break;
                g.p.Pos = sweep[shotIdx];
            }
        }
    }
}
