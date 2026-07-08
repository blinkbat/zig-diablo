const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
const loot = @import("loot.zig");
const player = @import("player.zig");
const input = @import("input.zig");

const GameState = state.GameState;
const Monster = monster.Monster;
const v3 = mathx.v3;
const rgba = mathx.rgba;
const distXZ = mathx.distXZ;
const dirXZ = mathx.dirXZ;
const lenXZ = mathx.lenXZ;

// updatePlaying advances the whole simulation by dt while in the playing scene.
pub fn updatePlaying(g: *GameState, dt_in: f32) void {
    // Clamp dt so a hitch can't tunnel entities through walls.
    var dt = dt_in;
    if (dt > 0.05) dt = 0.05;

    if (rl.isKeyPressed(.p)) g.paused = !g.paused;
    if (g.paused) return;

    input.updateAim(g);
    input.handleInput(g, dt);
    updateTimers(g, dt);

    updatePlayerMovement(g, dt);
    updatePlayerAttack(g, dt);

    for (g.monsters.items) |*m| {
        if (m.alive()) updateMonster(g, m, dt);
    }
    separateMonsters(g);
    updateProjectiles(g, dt);
    updateLoot(g, dt);
    updatePopups(g, dt);
    updateDeaths(g, dt);
    updatePortal(g);

    g.rig.follow(g.player.Pos, dt);
}

fn updateTimers(g: *GameState, dt: f32) void {
    const p = &g.player;
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

fn updatePlayerMovement(g: *GameState, dt: f32) void {
    const p = &g.player;

    // A dodge roll overrides all other movement and steering.
    if (p.rolling()) {
        const step = v3(p.rollDir.x * player.rollSpeed * dt, 0, p.rollDir.z * player.rollSpeed * dt);
        p.Pos = g.world.moveWithCollision(p.Pos, step, p.Radius);
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
            } else {
                p.targetMonster = -1;
            }
        } else {
            p.targetMonster = -1;
        }
    } else if (p.hasMoveTarget) {
        if (distXZ(p.Pos, p.moveTarget) > 0.25) {
            dir = dirXZ(p.Pos, p.moveTarget);
            moving = true;
        } else {
            p.hasMoveTarget = false;
        }
    }

    if (moving and lenXZ(dir) > 0) {
        p.Facing = dir;
        const step = v3(dir.x * p.Speed * dt, 0, dir.z * p.Speed * dt);
        p.Pos = g.world.moveWithCollision(p.Pos, step, p.Radius);
        p.walkBob += dt * 12;
    }
}

fn updatePlayerAttack(g: *GameState, dt: f32) void {
    _ = dt;
    const p = &g.player;
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
        const crit = g.rng.float() < 0.15;
        if (crit) dmg *= 2;
        p.Facing = dirXZ(p.Pos, m.Pos);
        p.swing = player.swingDur;
        p.atkCD = p.atkRate;
        damageMonster(g, m, dmg, crit);
    }
}

fn damageMonster(g: *GameState, m: *Monster, dmg: f32, crit: bool) void {
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

fn killMonster(g: *GameState, m: *Monster) void {
    m.HP = 0;
    m.dying = true;
    m.deathTimer = monster.monster_death_fade;
    g.kills += 1;
    if (g.player.addXP(m.XP)) onLevelUp(g);
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "+{d} XP", .{m.XP}) catch "";
    g.addPopup(v3(m.Pos.x, m.Pos.y + 0.5, m.Pos.z), txt, rgba(120, 200, 255, 255));
    loot.rollLoot(m, &g.rng, &g.loot);
    if (m.boss) g.setToast("{s} has been slain!", .{m.Name});
    if (g.player.targetMonster == m.id) g.player.targetMonster = -1;
}

fn onLevelUp(g: *GameState) void {
    g.setBanner("Level {d}!", .{g.player.Level});
    g.bannerTime = 2.2;
    g.shake = mathx.maxF(g.shake, 0.3);
    g.addPopup(v3(g.player.Pos.x, 2.2, g.player.Pos.z), "LEVEL UP", rgba(255, 230, 120, 255));
}

fn updateMonster(g: *GameState, m: *Monster, dt: f32) void {
    if (m.hitFlash > 0) m.hitFlash -= dt;
    if (m.atkCD > 0) m.atkCD -= dt;
    m.bob += dt * (m.Speed + 2);

    // Committed attack: freeze + telegraph, then strike. The player's window to roll.
    if (m.windup > 0) {
        m.windup -= dt;
        if (g.player.alive()) m.Facing = dirXZ(m.Pos, g.player.Pos);
        if (m.windup <= 0) {
            resolveMonsterAttack(g, m);
            m.atkCD = m.atkRate;
        }
        return;
    }

    const toPlayer = distXZ(m.Pos, g.player.Pos);
    if (!g.player.alive()) {
        m.aggro = false;
    } else if (!m.aggro and toPlayer < m.sightRange) {
        m.aggro = true;
    }

    if (!m.aggro) {
        // Idle wander.
        m.wanderTimer -= dt;
        if (m.wanderTimer <= 0) {
            m.wanderTimer = 1.5 + g.rng.float() * 2.5;
            if (g.rng.float() < 0.55) {
                const ang: f32 = @floatCast(g.rng.float64() * 2 * std.math.pi);
                m.wanderDir = v3(mathx.cosf(ang), 0, mathx.sinf(ang));
            } else {
                m.wanderDir = mathx.zero3;
            }
        }
        if (lenXZ(m.wanderDir) > 0) {
            m.Facing = m.wanderDir;
            moveMonster(g, m, m.wanderDir, dt * 0.45);
        }
        return;
    }

    m.Facing = dirXZ(m.Pos, g.player.Pos);
    if (m.Ranged) {
        if (toPlayer > m.atkRange * 0.85) {
            moveMonster(g, m, dirXZ(m.Pos, g.player.Pos), dt);
        } else if (toPlayer < m.atkRange * 0.35) {
            moveMonster(g, m, dirXZ(g.player.Pos, m.Pos), dt * 0.7); // kite back
        }
        if (toPlayer <= m.atkRange and m.atkCD <= 0) {
            m.windup = m.windupTime; // begin telegraphing the shot
        }
        return;
    }

    // Melee: close the gap, then commit to a telegraphed swing.
    if (toPlayer > m.atkRange + g.player.Radius) {
        moveMonster(g, m, dirXZ(m.Pos, g.player.Pos), dt);
    } else if (m.atkCD <= 0) {
        m.windup = m.windupTime;
    }
}

// resolveMonsterAttack lands a strike at the end of a windup, if still valid.
fn resolveMonsterAttack(g: *GameState, m: *Monster) void {
    if (!g.player.alive()) return;
    const dmg = m.MinDmg + g.rng.float() * (m.MaxDmg - m.MinDmg);
    if (m.Ranged) {
        g.projectiles.append(projectile.newArrow(m.Pos, dirXZ(m.Pos, g.player.Pos), dmg)) catch @panic("oom");
        return;
    }
    if (distXZ(m.Pos, g.player.Pos) <= m.atkRange + g.player.Radius + 0.35) {
        hitPlayer(g, dmg);
    }
}

fn moveMonster(g: *GameState, m: *Monster, dir: rl.Vector3, dt: f32) void {
    if (lenXZ(dir) < 1e-4) return;
    const step = v3(dir.x * m.Speed * dt, 0, dir.z * m.Speed * dt);
    m.Pos = g.world.moveWithCollision(m.Pos, step, m.Radius);
}

fn separateMonsters(g: *GameState) void {
    const items = g.monsters.items;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (!items[i].alive()) continue;
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (!items[j].alive()) continue;
            const d = distXZ(items[i].Pos, items[j].Pos);
            const minD = items[i].Radius + items[j].Radius;
            if (d > 1e-3 and d < minD) {
                const push = (minD - d) * 0.5;
                const dir = dirXZ(items[j].Pos, items[i].Pos);
                items[i].Pos = g.world.moveWithCollision(items[i].Pos, v3(dir.x * push, 0, dir.z * push), items[i].Radius);
                items[j].Pos = g.world.moveWithCollision(items[j].Pos, v3(-dir.x * push, 0, -dir.z * push), items[j].Radius);
            }
        }
    }
}

fn hitPlayer(g: *GameState, dmg: f32) void {
    // I-frames from a dodge roll negate the blow entirely.
    if (g.player.invulnerable()) {
        g.addPopup(v3(g.player.Pos.x, 2.0, g.player.Pos.z), "dodged", rgba(180, 220, 255, 230));
        return;
    }
    g.player.takeDamage(dmg);
    g.damageFlash = state.damageFlashDur;
    g.shake = mathx.maxF(g.shake, 0.25);
    var buf: [16]u8 = undefined;
    const di: i32 = @intFromFloat(dmg);
    const txt = std.fmt.bufPrint(&buf, "-{d}", .{di}) catch "";
    g.addPopup(v3(g.player.Pos.x, 2.0, g.player.Pos.z), txt, rgba(255, 90, 90, 255));
    if (!g.player.alive()) g.scene = .dead;
}

fn updateProjectiles(g: *GameState, dt: f32) void {
    var w: usize = 0;
    const items = g.projectiles.items;
    for (items) |*pr| {
        pr.Pos.x += pr.Vel.x * dt;
        pr.Pos.z += pr.Vel.z * dt;
        pr.Life -= dt;
        if (pr.Life <= 0 or g.world.rayHitsObstacle(pr.Pos, pr.Radius)) continue;
        var hit = false;
        if (pr.FromPlayer) {
            for (g.monsters.items) |*m| {
                if (m.alive() and distXZ(m.Pos, pr.Pos) < m.Radius + pr.Radius) {
                    damageMonster(g, m, pr.Damage, false);
                    hit = true;
                    break;
                }
            }
        } else if (g.player.alive() and distXZ(g.player.Pos, pr.Pos) < g.player.Radius + pr.Radius) {
            hitPlayer(g, pr.Damage);
            hit = true;
        }
        if (!hit) {
            items[w] = pr.*;
            w += 1;
        }
    }
    g.projectiles.shrinkRetainingCapacity(w);
}

fn updateLoot(g: *GameState, dt: f32) void {
    var w: usize = 0;
    const items = g.loot.items;
    for (items) |*d| {
        d.bob += dt * 3;
        if (distXZ(d.Pos, g.player.Pos) < g.player.Radius + 1.3) {
            collect(g, d.*);
            continue;
        }
        items[w] = d.*;
        w += 1;
    }
    g.loot.shrinkRetainingCapacity(w);
}

fn collect(g: *GameState, d: loot.LootDrop) void {
    switch (d.Kind) {
        .gold => {
            g.player.Gold += d.Amount;
            var buf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "+{d}g", .{d.Amount}) catch "";
            g.addPopup(g.player.Pos, txt, rgba(255, 215, 80, 255));
        },
        .health_potion => {
            if (g.player.HealthPots < player.maxPots) g.player.HealthPots += 1;
            g.setToast("Picked up a Health Potion", .{});
        },
        .mana_potion => {
            if (g.player.ManaPots < player.maxPots) g.player.ManaPots += 1;
            g.setToast("Picked up a Mana Potion", .{});
        },
    }
}

fn updatePopups(g: *GameState, dt: f32) void {
    var w: usize = 0;
    const items = g.popups.items;
    for (items) |*pp| {
        pp.Life -= dt;
        pp.Pos.y += dt * 1.4;
        if (pp.Life > 0) {
            items[w] = pp.*;
            w += 1;
        }
    }
    g.popups.shrinkRetainingCapacity(w);
}

fn updateDeaths(g: *GameState, dt: f32) void {
    var w: usize = 0;
    const items = g.monsters.items;
    for (items) |*m| {
        if (m.dying) {
            m.deathTimer -= dt;
            if (m.deathTimer <= 0) continue;
        }
        items[w] = m.*;
        w += 1;
    }
    g.monsters.shrinkRetainingCapacity(w);
}

fn updatePortal(g: *GameState) void {
    if (!g.world.PortalOpen and g.remainingMonsters() == 0) {
        g.world.PortalOpen = true;
        g.setToast("Area cleared - a portal has opened!", .{});
    }
    if (g.world.PortalOpen and distXZ(g.player.Pos, g.world.PortalPos) < 2.4) {
        if (g.world.IsLast) {
            g.scene = .victory;
        } else {
            g.enterArea(g.areaIndex + 1);
        }
    }
}
