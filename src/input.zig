const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");
const projectile = @import("projectile.zig");
const fow = @import("fow.zig");

const GameState = state.GameState;
const v3 = mathx.v3;
const rgba = mathx.rgba;
const distXZ = mathx.distXZ;
const dirXZ = mathx.dirXZ;
const lenXZ = mathx.lenXZ;

// The screen-bottom band occupied by the HUD; clicks there don't move the hero.
const hudReserve = 130;

pub fn handleInput(g: *GameState, dt: f32) void {
    _ = dt;
    const p = &g.player;

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
    if (lenXZ(kb) > 0) {
        const l = lenXZ(kb);
        g.kbMove = v3(kb.x / l, 0, kb.z / l);
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
        const items = g.monsters.items;
        if (g.hoverMonster >= 0 and g.hoverMonster < @as(i32, @intCast(items.len)) and items[@intCast(g.hoverMonster)].alive()) {
            p.targetMonster = items[@intCast(g.hoverMonster)].id;
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

// castFirebolt fires the player's spell if mana and cooldown allow.
fn castFirebolt(g: *GameState) void {
    const p = &g.player;
    if (p.castCD > 0 or p.Mana < p.spellCost) {
        if (p.Mana < p.spellCost) g.setToast("Not enough mana", .{});
        return;
    }
    var dir = dirXZ(p.Pos, g.mouseGround);
    if (lenXZ(dir) < 1e-4) dir = p.Facing;
    p.Facing = dir;
    p.Mana -= p.spellCost;
    p.castCD = 0.7;
    const dmg = p.spellDmg + @as(f32, @floatFromInt(g.rng.intn(8)));
    g.projectiles.append(projectile.newFirebolt(p.Pos, dir, dmg)) catch @panic("oom");
}

// updateAim refreshes the ground point under the cursor and the hovered monster.
pub fn updateAim(g: *GameState) void {
    const ray = rl.getScreenToWorldRay(rl.getMousePosition(), g.rig.cam);
    if (mathx.rayGround(ray)) |pt| g.mouseGround = pt;

    g.hoverMonster = -1;
    var best: f32 = std.math.floatMax(f32);
    for (g.monsters.items, 0..) |*m, i| {
        if (!m.alive() or !fow.inVision(g, m.Pos)) continue; // can't target what fog hides
        const d = distXZ(m.Pos, g.mouseGround);
        if (d < m.Radius + 0.6 and d < best) {
            best = d;
            g.hoverMonster = @intCast(i);
        }
    }
}
