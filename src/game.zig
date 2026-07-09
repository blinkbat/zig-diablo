const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const tl = @import("torchlight.zig");
const world = @import("world.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
const scenemesh = @import("scenemesh.zig");
const playermod = @import("player.zig");
const loot = @import("loot.zig");
const cameramod = @import("camera.zig");
const hudx = @import("hudx.zig");

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
// Bodies past this fade to black in the shader, so we skip drawing them; it also
// doubles as the vision radius that gates targeting / health bars / popups.
const CULL = TORCH_RADIUS + 3;

const DAMAGE_FLASH_DUR = 0.4;
const TOAST_DUR = 2.5;

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

// Popup is floating combat text anchored in the world. Its text lives inline in a
// fixed buffer so the popup is self-contained inside the ArrayList (no dangling slice).
pub const Popup = struct {
    Pos: rl.Vector3 = mathx.zero3,
    text_buf: [32]u8 = undefined,
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
    hoverMonster: i32 = -1,

    // Presentation timers + transient text.
    damageFlash: f32 = 0,
    shake: f32 = 0,
    banner_buf: [96]u8 = [_]u8{0} ** 96,
    banner_len: usize = 0,
    bannerTime: f32 = 0,
    toast_buf: [96]u8 = [_]u8{0} ** 96,
    toast_len: usize = 0,
    toastTime: f32 = 0,

    paused: bool = false,
    elapsed: f32 = 0,
    kills: i32 = 0,

    pub fn init(seed: u64) !Game {
        var torch = try tl.Torch.init();
        errdefer torch.deinit();
        var rng = mathx.Rng.init(seed);
        const lastArea = world.areas.len - 1;
        const w = world.buildWorld(world.areas[0], &rng, lastArea == 0);
        const sceneMesh = scenemesh.SceneMesh.init(&w, torch.scene, torch.depthShader);

        var g = Game{
            .rng = rng,
            .torch = torch,
            .sceneMesh = sceneMesh,
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
        g.setBanner("{s}", .{g.w.Name});
        g.bannerTime = 3.5;
        return g;
    }

    pub fn deinit(g: *Game) void {
        g.sceneMesh.deinit();
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
        g.setBanner("{s}", .{g.w.Name});
        g.bannerTime = 3.5;
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
        g.spawn(monster.makeBoss(def.tier, &g.rng, g.randomOpenTileNear(g.w.PortalPos, 8)));
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
        const s = std.fmt.bufPrintZ(&g.toast_buf, fmt, args) catch "";
        g.toast_len = s.len;
        g.toastTime = TOAST_DUR;
    }
    pub fn toastText(g: *const Game) [:0]const u8 {
        return g.toast_buf[0..g.toast_len :0];
    }
    pub fn setBanner(g: *Game, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrintZ(&g.banner_buf, fmt, args) catch "";
        g.banner_len = s.len;
    }
    pub fn bannerText(g: *const Game) [:0]const u8 {
        return g.banner_buf[0..g.banner_len :0];
    }

    pub fn addPopup(g: *Game, pos: rl.Vector3, txt: []const u8, col: rl.Color) void {
        var pp = Popup{ .Pos = v3(pos.x, 1.6, pos.z), .Color = col, .Life = 1.0, .maxLife = 1.0 };
        const n = @min(txt.len, pp.text_buf.len);
        @memcpy(pp.text_buf[0..n], txt[0..n]);
        pp.text_len = n;
        g.popups.append(pp) catch @panic("oom");
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
    if (g.bannerTime > 0) g.bannerTime -= dt;
    if (g.toastTime > 0) g.toastTime -= dt;
    p.regen(dt);
}

// ---- Input ----

// The screen-bottom band occupied by the HUD; clicks there don't move the hero.
const hudReserve = 130;

fn handleInput(g: *Game) void {
    const p = &g.p;

    // Zoom with the mouse wheel.
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) g.rig.addZoom(wheel);

    // Potions.
    if (rl.isKeyPressed(.one)) {
        if (p.drinkHealth()) g.setToast("Drank a Health Potion", .{});
    }
    if (rl.isKeyPressed(.two)) {
        if (p.drinkMana()) g.setToast("Drank a Mana Potion", .{});
    }

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
        if (p.startRoll(dir)) {
            g.addPopup(v3(p.Pos.x, 2.1, p.Pos.z), "Dodge!", rgba(180, 220, 255, 255));
        }
    }

    const mouse = rl.getMousePosition();
    const overHUD = mouse.y > @as(f32, @floatFromInt(rl.getScreenHeight() - hudReserve));

    // Left mouse: walk to point, or chase+attack the hovered monster.
    if (rl.isMouseButtonDown(.left) and !overHUD and lenXZ(g.kbMove) == 0 and !p.rolling()) {
        const ms = g.liveMonsters();
        if (g.hoverMonster >= 0 and g.hoverMonster < @as(i32, @intCast(ms.len)) and ms[@intCast(g.hoverMonster)].alive()) {
            p.targetMonster = ms[@intCast(g.hoverMonster)].id;
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
}

// updateAim refreshes the ground point under the cursor and the hovered monster.
fn updateAim(g: *Game) void {
    const ray = rl.getScreenToWorldRay(rl.getMousePosition(), g.rig.cam);
    if (mathx.rayGround(ray)) |pt| g.mouseGround = pt;

    g.hoverMonster = -1;
    var best: f32 = std.math.floatMax(f32);
    for (g.liveMonsters(), 0..) |*m, i| {
        if (!m.alive() or !g.inVision(m.Pos)) continue; // can't target what darkness hides
        const d = distXZ(m.Pos, g.mouseGround);
        if (d < m.Radius + 0.6 and d < best) {
            best = d;
            g.hoverMonster = @intCast(i);
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
                if (distXZ(p.Pos, m.Pos) > p.atkRange + m.Radius * 0.5) {
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
    if (distXZ(p.Pos, m.Pos) <= p.atkRange + m.Radius) {
        var dmg = p.MinDmg + g.rng.float() * (p.MaxDmg - p.MinDmg);
        const crit = g.rng.float() < CRIT_CHANCE;
        if (crit) dmg *= CRIT_MULT;
        p.Facing = dirXZ(p.Pos, m.Pos);
        p.swing = playermod.swingDur;
        p.atkCD = p.atkRate;
        damageMonster(g, m, dmg, crit);
    }
}

fn damageMonster(g: *Game, m: *Monster, dmg: f32, crit: bool) void {
    m.HP -= dmg;
    m.hitFlash = 0.12;
    m.aggro = true;
    const col = if (crit) rgba(255, 220, 60, 255) else rl.Color.white;
    var buf: [16]u8 = undefined;
    const di: i32 = @intFromFloat(dmg);
    const txt = if (crit)
        std.fmt.bufPrint(&buf, "{d}!", .{di}) catch ""
    else
        std.fmt.bufPrint(&buf, "{d}", .{di}) catch "";
    g.addPopup(m.Pos, txt, col);
    if (m.HP <= 0 and !m.dying) killMonster(g, m);
}

fn killMonster(g: *Game, m: *Monster) void {
    m.HP = 0;
    m.dying = true;
    m.deathTimer = monster.monster_death_fade;
    g.kills += 1;
    if (g.p.addXP(m.XP)) onLevelUp(g);
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "+{d} XP", .{m.XP}) catch "";
    g.addPopup(v3(m.Pos.x, m.Pos.y + 0.5, m.Pos.z), txt, rgba(120, 200, 255, 255));
    loot.rollLoot(m, &g.rng, &g.lootList);
    if (m.boss) g.setToast("{s} has been slain!", .{m.Name});
    if (g.p.targetMonster == m.id) g.p.targetMonster = -1;
}

fn onLevelUp(g: *Game) void {
    g.setBanner("Level {d}!", .{g.p.Level});
    g.bannerTime = 2.2;
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
    if (distXZ(m.Pos, g.p.Pos) <= meleeReach(m.atkRange, g.p.Radius)) hitPlayer(g, dmg);
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
    var buf: [16]u8 = undefined;
    const di: i32 = @intFromFloat(dmg);
    const txt = std.fmt.bufPrint(&buf, "-{d}", .{di}) catch "";
    g.addPopup(v3(g.p.Pos.x, 2.0, g.p.Pos.z), txt, rgba(255, 90, 90, 255));
    if (!g.p.alive()) g.scene = .dead;
}

// Advance projectiles: move, expire on lifetime/obstacle, damage what they strike.
fn updateProjectiles(g: *Game, dt: f32) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < g.projs.count) : (i += 1) {
        var pr = g.projs.buf[i];
        pr.Pos.x += pr.Vel.x * dt;
        pr.Pos.z += pr.Vel.z * dt;
        pr.Life -= dt;
        if (pr.Life <= 0 or g.w.rayHitsObstacle(pr.Pos, pr.Radius)) continue;
        var hit = false;
        if (pr.FromPlayer) {
            for (g.liveMonsters()) |*m| {
                if (m.alive() and distXZ(m.Pos, pr.Pos) < m.Radius + pr.Radius) {
                    damageMonster(g, m, pr.Damage, false);
                    hit = true;
                    break;
                }
            }
        } else if (g.p.alive() and distXZ(g.p.Pos, pr.Pos) < g.p.Radius + pr.Radius) {
            hitPlayer(g, pr.Damage);
            hit = true;
        }
        if (!hit) {
            g.projs.buf[wI] = pr;
            wI += 1;
        }
    }
    g.projs.count = wI;
}

// Loot: bob in place; collected when the player walks over it.
fn updateLoot(g: *Game, dt: f32) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < g.lootList.items.len) : (i += 1) {
        var d = g.lootList.items[i];
        d.bob += dt * 3;
        if (distXZ(d.Pos, g.p.Pos) < g.p.Radius + 1.3) {
            collect(g, d);
            continue;
        }
        g.lootList.items[wI] = d;
        wI += 1;
    }
    g.lootList.shrinkRetainingCapacity(wI);
}

fn collect(g: *Game, d: LootDrop) void {
    switch (d.Kind) {
        .gold => {
            g.p.Gold += d.Amount;
            var buf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "+{d}g", .{d.Amount}) catch "";
            g.addPopup(g.p.Pos, txt, rgba(255, 215, 80, 255));
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

fn updatePopups(g: *Game, dt: f32) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < g.popups.items.len) : (i += 1) {
        var pp = g.popups.items[i];
        pp.Life -= dt;
        pp.Pos.y += dt * 1.4;
        if (pp.Life > 0) {
            g.popups.items[wI] = pp;
            wI += 1;
        }
    }
    g.popups.shrinkRetainingCapacity(wI);
}

// Drop faded-out corpses, keeping live monsters packed contiguously at the front.
fn updateDeaths(g: *Game, dt: f32) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < g.monsterCount) : (i += 1) {
        if (g.monsters[i].dying) {
            g.monsters[i].deathTimer -= dt;
            if (g.monsters[i].deathTimer <= 0) continue;
        }
        if (wI != i) g.monsters[wI] = g.monsters[i];
        wI += 1;
    }
    g.monsterCount = wI;
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

// Depth pass: living bodies within CULL of the player cast. Bodies past the torch
// radius render black anyway, so there's no point shadowing them either.
fn drawMonstersCast(ms: []const Monster, player: rl.Vector3) void {
    for (ms) |*m| {
        if (m.dying) continue;
        if (distXZ(m.Pos, player) > CULL) continue;
        drawMonsterBody(m);
    }
}

fn drawMonstersLit(ms: []const Monster, player: rl.Vector3) void {
    for (ms) |*m| {
        if (distXZ(m.Pos, player) > CULL) continue;
        drawMonsterBody(m);
    }
}

// Emissive pass (no shadow): glowing eyes + the red attack telegraph + boss ring.
fn drawMonstersFX(ms: []const Monster, player: rl.Vector3) void {
    for (ms) |*m| {
        if (m.dying or !m.alive()) continue;
        if (distXZ(m.Pos, player) > CULL) continue;
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

fn drawProjectiles(projs: *ProjList) void {
    for (projs.items()) |*pr| {
        sphere(pr.Pos, pr.Radius, pr.Color);
        const tail = v3(pr.Pos.x - pr.Vel.x * 0.03, pr.Pos.y, pr.Pos.z - pr.Vel.z * 0.03);
        rl.drawCylinderEx(tail, pr.Pos, pr.Radius * 0.3, pr.Radius, 6, mathx.withAlpha(pr.Color, 130));
    }
}

fn drawLoot(lootList: *std.ArrayList(LootDrop), player: rl.Vector3) void {
    for (lootList.items) |*d| {
        if (distXZ(d.Pos, player) > CULL) continue;
        const y = 0.4 + 0.12 * sinf(d.bob);
        switch (d.Kind) {
            .gold => sphere(v3(d.Pos.x, y * 0.6, d.Pos.z), 0.26, rgba(255, 205, 60, 255)),
            .health_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), rgba(220, 40, 50, 255)),
            .mana_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), rgba(60, 110, 235, 255)),
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
    const ms = g.liveMonsters();
    const drawHero = g.p.alive();

    // --- depth pass (obstacle mesh + nearby monsters + player cast) ---
    g.torch.beginShadowPass(lp);
    g.sceneMesh.drawDepth();
    drawMonstersCast(ms, g.p.Pos);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endShadowPass();

    // --- main pass ---
    rl.beginDrawing();
    rl.clearBackground(rgba(16, 16, 22, 255));
    g.torch.applyUniforms(cam, lp);
    rl.beginMode3D(cam);
    g.torch.beginScene();
    // beginScene bound the shadow map on slot 10 and left it active; reset to 0 so
    // immediate-mode texture0 binds land on slot 0, not on the shadow map.
    rl.gl.rlActiveTextureSlot(0);
    g.sceneMesh.drawScene();
    rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(g.w.Half * 2, g.w.Half * 2), g.w.Ground);
    drawWalls(&g.w);
    drawMonstersLit(ms, g.p.Pos);
    if (drawHero) drawHeroBody(&g.p);
    g.torch.endScene();
    if (drawHero) drawHeroFX(&g.p, t);
    drawMonstersFX(ms, g.p.Pos);
    drawLoot(&g.lootList, g.p.Pos);
    drawProjectiles(&g.projs);
    drawPortal(&g.w, t);
    rl.endMode3D();
    return cam;
}

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    // Uncapped: no setTargetFPS. setTargetFPS paces by OS sleep, whose ~15.6ms Windows
    // timer granularity makes a 60fps target periodically oversleep into a dropped frame
    // (a "chug" despite ample headroom). Running free removes that jitter. To re-cap
    // smoothly later, prefer .vsync_hint (GPU flip pacing) over setTargetFPS.

    var g = Game.init(if (shot) 1234 else mathx.timeSeed()) catch return;
    defer g.deinit();

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
                if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space)) g.startRun();
                g.rig.follow(g.p.Pos, dt); // let the backdrop drift
            },
            .playing => {
                if (rl.isKeyPressed(.escape)) g.scene = .menu;
                updatePlaying(&g, dt);
            },
            .dead => {
                if (rl.isKeyPressed(.r)) g.startRun();
            },
            .victory => {
                if (rl.isKeyPressed(.enter)) g.startRun();
            },
        }

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
