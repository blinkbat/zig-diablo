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
const hudx = @import("hudx.zig");

const Monster = monster.Monster;
const Projectile = projectile.Projectile;
const Player = playermod.Player;
const LootDrop = loot.LootDrop;

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

const MAX_MONSTERS = 128;
const CAST_RATE = 0.7; // firebolt cooldown (seconds)

// The game, rebuilt on the demo's exact lighting (torchlight.zig, copied verbatim
// from the frozen demo2.zig). The lighting is NOT to be altered here.
//
// Layered back in one testable step at a time on top of the verified CHUNK 1 base
// (ground + WASD player + torch + follow camera):
//   LAYER 1: the real arena floor + boundary walls, sized/colored to area 0.
//   LAYER 2: boulders — the SHORT casters, drawn in plain tint; torchlight lights
//     + shadows them. (Also fixed the real bug behind every earlier "break": a busy
//     scene overflows raylib's render batch, whose auto-flush drops the shadow map
//     on slot 10 — see keepShadowBound.)
//   LAYER 3: gravestones. Obstacle drawing generalized.
//   LAYER 4 — finished the world: all obstacle kinds, slide-along collision, spawn.
//   LAYER 5 (this step) — monsters + melee combat: spawn packs, the wander → aggro
//     → chase → telegraph → strike AI, monster bodies as real shadow casters, and
//     player melee (Space) with HP / death. Area 0's kinds are all melee.
//   Next: ranged skeletons + projectiles → boss → loot → HUD.

// A melee monster's true reach: its attack range, plus the target's radius, plus a
// small lunge. The strike check and the drawn telegraph ring MUST use this same
// formula so that standing just outside the ring is genuinely safe.
const MELEE_LUNGE = 0.35;
fn meleeReach(atkRange: f32, targetRadius: f32) f32 {
    return atkRange + targetRadius + MELEE_LUNGE;
}

// Follow camera: the demo's iso angle (offset 0,26,24 from the look-at point), but
// tracking the player instead of the origin. Feeds viewPos to the shader exactly as
// the demo's fixed camera did — a view change, not a lighting one.
fn followCamera(player: rl.Vector3) rl.Camera3D {
    return .{
        .position = v3(player.x, 26, player.z + 24),
        .target = v3(player.x, 1, player.z),
        .up = v3(0, 1, 0),
        .fovy = 50,
        .projection = .perspective,
    };
}

// Low-poly sphere. raylib's drawSphere defaults to 16x16 (~1.5k verts) and
// regenerates on the CPU with per-vertex trig on every call — and the whole scene is
// drawn twice a frame (shadow depth pass + main pass). Under a dark torch an 8x8 ball
// is indistinguishable, at ~1/4 the CPU cost. This is the single biggest frame win.
fn sphere(pos: rl.Vector3, r: f32, col: rl.Color) void {
    rl.drawSphereEx(pos, r, 8, 8, col);
}

// The hero: a cloaked, hooded ranger with legs, a bow, and a torch stick (ported
// from render.zig, plain tint — torchlight shades + shadows it). This is the caster.
fn drawHeroBody(p: *const Player) void {
    const base = p.Pos;
    const bob = 0.05 * sinf(p.walkBob);
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);

    var cloak = rgba(54, 74, 60, 255);
    const hood = rgba(44, 60, 50, 255);
    const skin = rgba(208, 176, 140, 255);

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

// Emissive hero bits (no shadow): bowstring, the flickering torch flame + rising
// embers (the visible light source), and a faint footprint ring.
fn drawHeroFX(p: *const Player, t: f32) void {
    const base = p.Pos;
    const f = mathx.orFacing(p.Facing, 0, -1);
    const right = mathx.perpXZ(f);

    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15, base.z - f.z * 0.18 + right.z * 0.4);
    rl.drawLine3D(v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18), v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18), rgba(200, 200, 190, 200));

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

// ---- Monsters ----

fn randomOpenTile(w: *const world.World, rng: *mathx.Rng, from: rl.Vector3, minFrom: f32) rl.Vector3 {
    const h = w.Half - 3;
    var attempt: i32 = 0;
    while (attempt < 60) : (attempt += 1) {
        const p = mathx.ground((rng.float() * 2 - 1) * h, (rng.float() * 2 - 1) * h);
        if (distXZ(p, from) < minFrom) continue;
        if (!w.blocked(p, 1.0)) return p;
    }
    return mathx.ground(0, 0);
}

fn randomOpenTileNear(w: *const world.World, rng: *mathx.Rng, center: rl.Vector3, spread: f32) rl.Vector3 {
    var attempt: i32 = 0;
    while (attempt < 40) : (attempt += 1) {
        const p = mathx.ground(center.x + (rng.float() * 2 - 1) * spread, center.z + (rng.float() * 2 - 1) * spread);
        if (!w.blocked(p, 0.8)) return p;
    }
    return center;
}

// Scatter melee packs across the arena, away from the player's spawn.
fn spawnMonsters(w: *const world.World, rng: *mathx.Rng, buf: []Monster) usize {
    const def = world.areas[0];
    const spawn = world.startPos(w.*);
    var n: usize = 0;
    var pack: i32 = 0;
    while (pack < def.packs and n < buf.len) : (pack += 1) {
        const center = randomOpenTile(w, rng, spawn, 16);
        const packSize = 2 + rng.intn(3);
        const kind = def.kinds[@intCast(rng.intn(@intCast(def.kinds.len)))];
        var i: i32 = 0;
        while (i < packSize and n < buf.len) : (i += 1) {
            buf[n] = monster.makeMonster(kind, def.tier, rng, randomOpenTileNear(w, rng, center, 5));
            n += 1;
        }
    }
    // One boss per area, placed far from the spawn.
    if (n < buf.len) {
        buf[n] = monster.makeBoss(def.tier, rng, randomOpenTile(w, rng, spawn, 24));
        n += 1;
    }
    return n;
}

fn moveMonster(m: *Monster, w: *const world.World, dir: rl.Vector3, dt: f32) void {
    if (lenXZ(dir) < 1e-4) return;
    m.Pos = w.moveWithCollision(m.Pos, v3(dir.x * m.Speed * dt, 0, dir.z * m.Speed * dt), m.Radius);
}

// Apply player damage to a monster; on the killing blow, award XP and roll its loot.
fn hurtMonster(m: *Monster, dmg: f32, p: *Player, lootList: *std.ArrayList(LootDrop), rng: *mathx.Rng) void {
    m.HP -= dmg;
    m.hitFlash = 0.12;
    m.aggro = true;
    if (m.HP <= 0 and !m.dying) {
        m.dying = true;
        m.deathTimer = monster.monster_death_fade;
        _ = p.addXP(m.XP);
        loot.rollLoot(m, rng, lootList);
    }
}

// Land a strike at the end of a windup: melee damages the player if still in reach;
// ranged looses an arrow toward them.
fn resolveMonsterAttack(m: *Monster, p: *Player, rng: *mathx.Rng, projs: *ProjList) void {
    const dmg = m.MinDmg + rng.float() * (m.MaxDmg - m.MinDmg);
    if (m.Ranged) {
        projs.add(projectile.newArrow(m.Pos, dirXZ(m.Pos, p.Pos), dmg));
        return;
    }
    if (distXZ(m.Pos, p.Pos) <= meleeReach(m.atkRange, p.Radius)) p.takeDamage(dmg);
}

// One monster's AI for the frame. Mirrors update.zig (melee + ranged paths).
fn updateMonster(m: *Monster, w: *const world.World, p: *Player, dt: f32, rng: *mathx.Rng, projs: *ProjList) void {
    if (m.hitFlash > 0) m.hitFlash -= dt;
    if (m.atkCD > 0) m.atkCD -= dt;
    m.bob += dt * (m.Speed + 2);

    // Committed strike: freeze + telegraph, then land it.
    if (m.windup > 0) {
        m.windup -= dt;
        m.Facing = dirXZ(m.Pos, p.Pos);
        if (m.windup <= 0) {
            resolveMonsterAttack(m, p, rng, projs);
            m.atkCD = m.atkRate;
        }
        return;
    }

    const toPlayer = distXZ(m.Pos, p.Pos);
    if (!m.aggro and toPlayer < m.sightRange) m.aggro = true;

    if (!m.aggro) {
        m.wanderTimer -= dt;
        if (m.wanderTimer <= 0) {
            m.wanderTimer = 1.5 + rng.float() * 2.5;
            if (rng.float() < 0.55) {
                const ang: f32 = @floatCast(rng.float64() * 2 * std.math.pi);
                m.wanderDir = v3(cosf(ang), 0, sinf(ang));
            } else m.wanderDir = mathx.zero3;
        }
        if (lenXZ(m.wanderDir) > 0) {
            m.Facing = m.wanderDir;
            moveMonster(m, w, m.wanderDir, dt * 0.45);
        }
        return;
    }

    m.Facing = dirXZ(m.Pos, p.Pos);
    if (m.Ranged) {
        // Kite: hold at range, back off if the player gets close, then shoot.
        if (toPlayer > m.atkRange * 0.85) {
            moveMonster(m, w, dirXZ(m.Pos, p.Pos), dt);
        } else if (toPlayer < m.atkRange * 0.35) {
            moveMonster(m, w, dirXZ(p.Pos, m.Pos), dt * 0.7);
        }
        if (toPlayer <= m.atkRange and m.atkCD <= 0) m.windup = m.windupTime;
        return;
    }

    // Melee: close the gap, then commit to a telegraphed swing.
    if (toPlayer > m.atkRange + p.Radius) {
        moveMonster(m, w, dirXZ(m.Pos, p.Pos), dt);
    } else if (m.atkCD <= 0) {
        m.windup = m.windupTime;
    }
}

// Push overlapping monsters apart so a pack doesn't collapse into one point.
fn separateMonsters(ms: []Monster, w: *const world.World) void {
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
                ms[i].Pos = w.moveWithCollision(ms[i].Pos, v3(dir.x * push, 0, dir.z * push), ms[i].Radius);
                ms[j].Pos = w.moveWithCollision(ms[j].Pos, v3(-dir.x * push, 0, -dir.z * push), ms[j].Radius);
            }
        }
    }
}

fn updateMonsters(ms: []Monster, w: *const world.World, p: *Player, dt: f32, rng: *mathx.Rng, projs: *ProjList) void {
    for (ms) |*m| {
        if (m.dying) {
            m.deathTimer -= dt;
        } else if (m.alive()) {
            updateMonster(m, w, p, dt, rng, projs);
        }
    }
    separateMonsters(ms, w);
}

// Advance projectiles: move, expire on lifetime/obstacle, damage what they strike.
// Player bolts hit monsters; monster arrows hit the player. Survivors stay packed.
fn updateProjectiles(projs: *ProjList, w: *const world.World, ms: []Monster, p: *Player, dt: f32, lootList: *std.ArrayList(LootDrop), rng: *mathx.Rng) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < projs.count) : (i += 1) {
        var pr = projs.buf[i];
        pr.Pos.x += pr.Vel.x * dt;
        pr.Pos.z += pr.Vel.z * dt;
        pr.Life -= dt;
        if (pr.Life <= 0 or w.rayHitsObstacle(pr.Pos, pr.Radius)) continue;
        var hit = false;
        if (pr.FromPlayer) {
            for (ms) |*m| {
                if (m.alive() and distXZ(m.Pos, pr.Pos) < m.Radius + pr.Radius) {
                    hurtMonster(m, pr.Damage, p, lootList, rng);
                    hit = true;
                    break;
                }
            }
        } else if (distXZ(p.Pos, pr.Pos) < p.Radius + pr.Radius) {
            p.takeDamage(pr.Damage);
            hit = true;
        }
        if (!hit) {
            projs.buf[wI] = pr;
            wI += 1;
        }
    }
    projs.count = wI;
}

// Emissive projectiles: a glowing head with a short motion-trail tail.
fn drawProjectiles(projs: *ProjList) void {
    for (projs.items()) |*pr| {
        sphere(pr.Pos, pr.Radius, pr.Color);
        const tail = v3(pr.Pos.x - pr.Vel.x * 0.03, pr.Pos.y, pr.Pos.z - pr.Vel.z * 0.03);
        rl.drawCylinderEx(tail, pr.Pos, pr.Radius * 0.3, pr.Radius, 6, mathx.withAlpha(pr.Color, 130));
    }
}

// Drop faded-out corpses; returns the new live count (kept contiguous at the front).
fn compactMonsters(buf: []Monster, count: usize) usize {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (buf[i].dying and buf[i].deathTimer <= 0) continue;
        // Monster is a large struct; skip the copy until something has been dropped
        // (the common no-death frame moves nothing).
        if (wI != i) buf[wI] = buf[i];
        wI += 1;
    }
    return wI;
}

// Player melee: hit the nearest monster within reach.
fn playerAttack(ms: []Monster, p: *Player, lootList: *std.ArrayList(LootDrop), rng: *mathx.Rng) void {
    var best: f32 = 1e9;
    var bi: ?usize = null;
    for (ms, 0..) |*m, idx| {
        if (!m.alive()) continue;
        const d = distXZ(m.Pos, p.Pos);
        if (d <= p.atkRange + m.Radius and d < best) {
            best = d;
            bi = idx;
        }
    }
    if (bi) |idx| {
        hurtMonster(&ms[idx], p.MinDmg + rng.float() * (p.MaxDmg - p.MinDmg), p, lootList, rng);
    }
}

// Loot: bob in place; collected when the player walks over it (gold → purse,
// potions → belt, capped). Compacts the list, dropping collected drops.
fn updateLoot(lootList: *std.ArrayList(LootDrop), p: *Player, dt: f32) void {
    var wI: usize = 0;
    var i: usize = 0;
    while (i < lootList.items.len) : (i += 1) {
        var d = lootList.items[i];
        d.bob += dt * 3;
        if (distXZ(d.Pos, p.Pos) < p.Radius + 1.3) {
            switch (d.Kind) {
                .gold => p.Gold += d.Amount,
                .health_potion => if (p.HealthPots < playermod.maxPots) {
                    p.HealthPots += 1;
                },
                .mana_potion => if (p.ManaPots < playermod.maxPots) {
                    p.ManaPots += 1;
                },
            }
            continue;
        }
        lootList.items[wI] = d;
        wI += 1;
    }
    lootList.shrinkRetainingCapacity(wI);
}

// Emissive loot (glints visible in the dark): gold ball, colored potion cubes.
fn drawLoot(lootList: *std.ArrayList(LootDrop), player: rl.Vector3, cull: f32) void {
    for (lootList.items) |*d| {
        if (distXZ(d.Pos, player) > cull) continue;
        const y = 0.4 + 0.12 * sinf(d.bob);
        switch (d.Kind) {
            .gold => sphere(v3(d.Pos.x, y * 0.6, d.Pos.z), 0.26, rgba(255, 205, 60, 255)),
            .health_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), rgba(220, 40, 50, 255)),
            .mana_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), rgba(60, 110, 235, 255)),
        }
    }
}

// Shared monster body proportions, so the lit body (drawMonsterBody) and the emissive
// eyes (drawMonstersFX) agree on where the head is instead of each re-deriving it.
const MONSTER_BOB_AMP = 0.05; // walk-bob height
const MONSTER_TORSO_BASE = 0.4; // torso bottom above the ground
const MONSTER_HEAD_GAP = 0.25; // head-sphere center above the torso top

fn monsterBob(m: *const Monster) f32 {
    return MONSTER_BOB_AMP * sinf(m.bob);
}
// Y of the head-sphere center; `shrink` (<1 during the death fade) collapses it.
fn monsterHeadY(m: *const Monster, shrink: f32) f32 {
    return MONSTER_TORSO_BASE + (m.Height - 0.5) * shrink + MONSTER_HEAD_GAP * shrink + monsterBob(m);
}

// Lit body: capsule torso + head, plain tint (torchlight shades + shadows it). Hit
// flashes white, a windup reddens, death shrinks it away.
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

// Depth pass: living bodies within `cull` of the player cast. Bodies past the torch
// radius render black anyway, so there's no point shadowing them either.
fn drawMonstersCast(ms: []const Monster, player: rl.Vector3, cull: f32) void {
    for (ms) |*m| {
        if (m.dying) continue;
        if (distXZ(m.Pos, player) > cull) continue;
        drawMonsterBody(m);
    }
}

// Main pass: bodies within `cull` (beyond the torch radius they'd be pure black).
// Total immediate geometry now stays well under the batch limit (obstacles are a
// baked mesh), so no manual flushing is needed.
fn drawMonstersLit(ms: []const Monster, player: rl.Vector3, cull: f32) void {
    for (ms) |*m| {
        if (distXZ(m.Pos, player) > cull) continue;
        drawMonsterBody(m);
    }
}

// Emissive pass (no shadow): glowing eyes + the red attack telegraph.
fn drawMonstersFX(ms: []const Monster, player: rl.Vector3) void {
    for (ms) |*m| {
        if (m.dying or !m.alive()) continue;
        if (m.boss) {
            rl.drawCircle3D(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.4, v3(1, 0, 0), 90, rgba(255, 60, 60, 200));
        }
        if (m.windup > 0) {
            const tp = 1 - m.windup / m.windupTime;
            const a = mathx.u8f(clampF(110 + 130 * tp, 0, 255));
            if (m.Ranged) {
                // Ranged shot: an aim line to the player, not a ground ring.
                rl.drawCylinderEx(v3(m.Pos.x, 1.2, m.Pos.z), v3(player.x, 0.3, player.z), 0.05, 0.05, 4, rgba(255, 70, 50, a));
            } else {
                // Melee AoE ring sized to the ACTUAL hit reach (see meleeReach),
                // so standing just outside the ring is truly safe.
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

fn remainingMonsters(ms: []const Monster) usize {
    var n: usize = 0;
    for (ms) |*m| {
        if (m.alive()) n += 1;
    }
    return n;
}

// Emissive exit portal: a dim disc while the area is uncleared, a swirling blue-violet
// column once it opens.
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

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    // Uncapped: no setTargetFPS. setTargetFPS paces by OS sleep, whose ~15.6ms Windows
    // timer granularity makes a 60fps target periodically oversleep into a dropped frame
    // (a "chug" despite ample headroom). Running free removes that jitter and lets drawFPS
    // report the true achievable rate. To re-cap smoothly later, prefer .vsync_hint (GPU
    // flip pacing, no sleep-granularity problem) over setTargetFPS.

    var torch = tl.Torch.init() catch return;
    defer torch.deinit();

    var rng = mathx.Rng.init(if (shot) 1234 else mathx.timeSeed());

    const lastArea = world.areas.len - 1;
    var areaIndex: usize = 0;
    var w = world.buildWorld(world.areas[areaIndex], &rng, areaIndex == lastArea);

    // Bake the static obstacles into one GPU mesh per area (no per-frame CPU regen).
    var scene = scenemesh.SceneMesh.init(&w, torch.scene, torch.depthShader);
    defer scene.deinit();

    var monsters: [MAX_MONSTERS]Monster = undefined;
    var monsterCount = spawnMonsters(&w, &rng, &monsters);

    var lootList = std.ArrayList(LootDrop).init(std.heap.c_allocator);
    defer lootList.deinit();

    var p = playermod.newPlayer(world.startPos(w));
    var torchHeight: f32 = 6.0; // demo default (Q/E to tune)
    var torchRadius: f32 = 12.0; // demo default (wheel to tune)
    var projs = ProjList{};
    var mouseGround = mathx.zero3;
    var won = false;
    var bannerTime: f32 = 3.5; // area-name banner, counts down

    const sweep = [_]rl.Vector3{ world.startPos(w), mathx.ground(0, 0) };
    if (shot) p.Pos = sweep[0];
    var frame: i32 = 0;
    var shotIdx: usize = 0;

    var remaining: usize = 0; // live monster count, computed once per frame (below)
    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const t: f32 = @floatCast(rl.getTime());
        if (bannerTime > 0) bannerTime -= dt;

        if (!won) {
            // --- movement + torch tuning ---
            const speed = 10.0 * dt;
            var delta = mathx.zero3;
            if (rl.isKeyDown(.w)) delta.z -= speed;
            if (rl.isKeyDown(.s)) delta.z += speed;
            if (rl.isKeyDown(.a)) delta.x -= speed;
            if (rl.isKeyDown(.d)) delta.x += speed;
            p.Pos = w.moveWithCollision(p.Pos, delta, p.Radius); // slides along walls + scenery
            if (lenXZ(delta) > 0) { // face the walk direction and advance the walk-bob
                p.Facing = dirXZ(mathx.zero3, delta);
                p.walkBob += dt * 12;
            }
            if (rl.isKeyDown(.q)) torchHeight = mathx.clampF(torchHeight - 12.0 * dt, 5, 30);
            if (rl.isKeyDown(.e)) torchHeight = mathx.clampF(torchHeight + 12.0 * dt, 5, 30);
            torchRadius = mathx.clampF(torchRadius + rl.getMouseWheelMove() * 1.5, 4, 28);

            // --- combat + progression sim ---
            if (p.atkCD > 0) p.atkCD -= dt;
            if (p.castCD > 0) p.castCD -= dt;
            if (p.hitFlash > 0) p.hitFlash -= dt; // was never decremented → stuck red flash
            p.regen(dt);
            if (rl.isKeyPressed(.one)) _ = p.drinkHealth();
            if (rl.isKeyPressed(.two)) _ = p.drinkMana();
            if (rl.isKeyPressed(.space) and p.atkCD <= 0) {
                playerAttack(monsters[0..monsterCount], &p, &lootList, &rng);
                p.atkCD = p.atkRate;
            }
            if (rl.isMouseButtonPressed(.right) and p.castCD <= 0 and p.Mana >= p.spellCost) {
                var dir = dirXZ(p.Pos, mouseGround);
                if (lenXZ(dir) < 1e-4) dir = v3(0, 0, -1);
                p.Mana -= p.spellCost;
                projs.add(projectile.newFirebolt(p.Pos, dir, p.spellDmg + @as(f32, @floatFromInt(rng.intn(8)))));
                p.castCD = CAST_RATE;
            }
            updateMonsters(monsters[0..monsterCount], &w, &p, dt, &rng, &projs);
            updateProjectiles(&projs, &w, monsters[0..monsterCount], &p, dt, &lootList, &rng);
            updateLoot(&lootList, &p, dt);
            monsterCount = compactMonsters(&monsters, monsterCount);
            remaining = remainingMonsters(monsters[0..monsterCount]);

            // Clearing the area opens the exit portal.
            if (!w.PortalOpen and remaining == 0) w.PortalOpen = true;
            // Stepping into an open portal advances the run (or wins on the last area).
            if (w.PortalOpen and distXZ(p.Pos, w.PortalPos) < 2.4) {
                if (w.IsLast) {
                    won = true;
                } else {
                    areaIndex += 1;
                    w = world.buildWorld(world.areas[areaIndex], &rng, areaIndex == lastArea);
                    scene.rebuild(&w);
                    monsterCount = spawnMonsters(&w, &rng, &monsters);
                    lootList.clearRetainingCapacity();
                    projs.count = 0;
                    p.Pos = world.startPos(w);
                    p.HP = p.MaxHP;
                    p.Mana = p.MaxMana;
                    bannerTime = 3.5;
                }
            }

            // Death restarts the run from the first area with a fresh hero.
            if (!p.alive()) {
                areaIndex = 0;
                w = world.buildWorld(world.areas[areaIndex], &rng, false);
                scene.rebuild(&w);
                monsterCount = spawnMonsters(&w, &rng, &monsters);
                lootList.clearRetainingCapacity();
                projs.count = 0;
                p = playermod.newPlayer(world.startPos(w));
                bannerTime = 3.5;
            }
        }

        const cam = followCamera(p.Pos);
        {
            const ray = rl.getScreenToWorldRay(rl.getMousePosition(), cam);
            if (mathx.rayGround(ray)) |pt| mouseGround = pt;
        }
        const lp = tl.LightParams{ .pos = v3(p.Pos.x, torchHeight, p.Pos.z), .radius = torchRadius };
        // Bodies past this fade to black in the shader, so we skip drawing them.
        const cull = torchRadius + 3;

        // --- depth pass (obstacle mesh + nearby monsters + player cast) ---
        torch.beginShadowPass(lp);
        scene.drawDepth();
        drawMonstersCast(monsters[0..monsterCount], p.Pos, cull);
        drawHeroBody(&p);
        torch.endShadowPass();

        // --- main pass ---
        rl.beginDrawing();
        rl.clearBackground(rgba(16, 16, 22, 255));
        torch.applyUniforms(cam, lp);
        rl.beginMode3D(cam);
        torch.beginScene();
        // beginScene bound the shadow map on slot 10 and left that slot active; reset
        // to 0 so immediate-mode texture0 binds land on slot 0, not on the shadow map.
        rl.gl.rlActiveTextureSlot(0);
        scene.drawScene(); // baked static obstacles (one GPU call)
        rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(w.Half * 2, w.Half * 2), w.Ground);
        drawWalls(&w);
        drawMonstersLit(monsters[0..monsterCount], p.Pos, cull);
        drawHeroBody(&p);
        torch.endScene();
        drawHeroFX(&p, t); // emissive torch flame (the visible light) + bowstring
        drawMonstersFX(monsters[0..monsterCount], p.Pos); // emissive: eyes + telegraphs + boss ring
        drawLoot(&lootList, p.Pos, cull);
        drawProjectiles(&projs);
        drawPortal(&w, t);
        rl.endMode3D();

        rl.drawText("WASD move   Space melee   RMB firebolt   1/2 potions   Q/E torch   wheel: radius", 20, 12, 18, rgba(200, 200, 200, 170));
        rl.drawFPS(20, 36);
        hudx.draw(&p, w.Name, remaining, bannerTime, won);
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
                p.Pos = sweep[shotIdx];
            }
        }
    }
}
