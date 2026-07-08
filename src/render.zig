const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");
const lighting = @import("lighting.zig");
const fow = @import("fow.zig");
const shadow = @import("shadow.zig");
const hud = @import("hud.zig");
const world = @import("world.zig");
const monster = @import("monster.zig");
const player = @import("player.zig");

const GameState = state.GameState;
const Monster = monster.Monster;
const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const withAlpha = mathx.withAlpha;
const clampF = mathx.clampF;
const distXZ = mathx.distXZ;
const orFacing = mathx.orFacing;
const perpXZ = mathx.perpXZ;
const sinf = mathx.sinf;
const cosf = mathx.cosf;

// Extra caster cull distance. The shadow pass tightens this so only casters near
// the hero are projected (perf; directional shadows are bounded regardless).
// Normal passes leave it effectively infinite.
pub var casterCull: f32 = 1e9;

// A flat ring lying on the ground (a circle rotated onto the XZ plane).
fn groundRing(center: rl.Vector3, radius: f32, color: rl.Color) void {
    rl.drawCircle3D(center, radius, v3(1, 0, 0), 90, color);
}

// drawWorld3D renders the scene: a shadow depth pass, then lit geometry under
// the lighting shader, then emissive elements with the default shader. (render.go)
pub fn drawWorld3D(g: *GameState) void {
    var cam = g.rig.cam;
    if (g.shake > 0) {
        const amp = g.shake * 0.7;
        cam.position.x += amp * sinf(g.elapsed * 63);
        cam.position.y += amp * cosf(g.elapsed * 71);
    }

    // Pass 0: depth shadow map from the torch point light.
    if (g.shadowsActive()) shadow.renderShadowMap(g);

    rl.clearBackground(lighting.fogColor);
    rl.beginMode3D(cam);

    // Pass 1: lit geometry — torch pool + fog + cast shadows sampled in the shader.
    if (g.shaderActive()) {
        lighting.applyLightUniforms(g, cam);
        rl.beginShaderMode(g.lightShader);
        if (g.shadowsActive()) {
            rl.gl.rlActiveTextureSlot(shadow.shadowSlot);
            rl.gl.rlEnableTexture(@intCast(g.shadowMap.depth.id));
            rl.gl.rlActiveTextureSlot(0);
        }
    }
    drawGround(g);
    drawWalls(g);
    drawObstacles(g);
    drawMonsterBodies(g);
    drawPlayerBody(g);
    if (g.shaderActive()) rl.endShaderMode();

    // Pass 2: emissive / glowing elements.
    drawMonsterFX(g);
    drawPlayerFX(g);
    drawLoot(g);
    drawProjectiles(g);
    drawPortal(g);

    rl.endMode3D();

    hud.drawWorldOverlays(g, cam);
}

// drawCasters draws only shadow-casting geometry, for the torch depth pass.
// (Ground receives shadows but doesn't cast, so it's excluded.)
pub fn drawCasters(g: *GameState) void {
    drawObstacles(g);
    drawMonsterBodies(g);
    drawPlayerBody(g);
}

fn drawGround(g: *GameState) void {
    const h = g.world.Half;
    rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(h * 2, h * 2), lighting.surf(g, g.world.Ground, v3(0, 0, 0)));
}

fn drawWalls(g: *GameState) void {
    const h = g.world.Half;
    const wallH = 4.0;
    const t = 1.2;
    const col = g.world.Accent;
    const segs = [_]rl.Vector3{
        v3(0, wallH / 2, -h), v3(0, wallH / 2, h),
        v3(-h, wallH / 2, 0), v3(h, wallH / 2, 0),
    };
    const sizes = [_]rl.Vector3{
        v3(h * 2 + t, wallH, t), v3(h * 2 + t, wallH, t),
        v3(t, wallH, h * 2 + t), v3(t, wallH, h * 2 + t),
    };
    for (segs, sizes) |seg, size| {
        rl.drawCubeV(seg, size, lighting.surf(g, col, seg));
    }
}

// Beyond this range scenery is lost to fog anyway; culling ~halves draw calls.
const obstacleDrawRange = 46;

fn drawObstacles(g: *GameState) void {
    for (g.world.obs()) |o| {
        if (distXZ(o.Pos, g.player.Pos) > obstacleDrawRange) continue;
        if (distXZ(o.Pos, g.player.Pos) > casterCull) continue;
        switch (o.Kind) {
            .tree => drawTree(g, o),
            .gravestone => drawGravestone(g, o),
            .rock => drawBoulder(g, o),
        }
    }
}

fn drawTree(g: *GameState, o: world.Obstacle) void {
    const bark = o.Tint;
    const x = o.Pos.x;
    const z = o.Pos.z;
    lighting.drawShadow(g, o.Pos, o.Radius * 1.4);

    const segs_n = 4;
    const lean = v3(0.12, 0, 0.05);
    var prev = v3(x, 0, z);
    var i: i32 = 1;
    while (i <= segs_n) : (i += 1) {
        const f: f32 = @as(f32, @floatFromInt(i)) / segs_n;
        const top = v3(x + lean.x * o.Height * f * f, o.Height * 0.62 * f, z + lean.z * o.Height * f * f);
        const r0 = 0.38 * (1 - 0.6 * @as(f32, @floatFromInt(i - 1)) / segs_n);
        const r1 = 0.38 * (1 - 0.6 * f);
        rl.drawCylinderEx(prev, top, r0, r1, 8, lighting.surf(g, bark, prev));
        prev = top;
    }
    const crown = prev;

    const branchCol = lerpColor(bark, rl.Color.black, 0.2);
    var j: i32 = 0;
    while (j < 5) : (j += 1) {
        const jf: f32 = @floatFromInt(j);
        const ang = jf * (2.0 * std.math.pi / 5.0) + 0.5;
        const out = 0.9 + 0.5 * sinf(o.Height + jf);
        const tip = v3(crown.x + cosf(ang) * out, crown.y + 0.5 + 0.4 * sinf(jf), crown.z + sinf(ang) * out);
        rl.drawCylinderEx(crown, tip, 0.16, 0.04, 5, lighting.surf(g, branchCol, crown));
    }

    const canopy = lerpColor(o.Tint, rgba(20, 32, 22, 255), 0.7);
    var k: i32 = 0;
    while (k < 3) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ang = kf * 2.1 + o.Height;
        const cp = v3(crown.x + cosf(ang) * 0.6, crown.y + 0.4 + kf * 0.25, crown.z + sinf(ang) * 0.6);
        rl.drawSphere(cp, o.Radius * 0.8, lighting.surf(g, canopy, cp));
    }
}

fn drawBoulder(g: *GameState, o: world.Obstacle) void {
    lighting.drawShadow(g, o.Pos, o.Radius * 1.2);
    rl.drawSphere(v3(o.Pos.x, o.Height * 0.35, o.Pos.z), o.Radius, lighting.surf(g, o.Tint, o.Pos));
    rl.drawSphere(v3(o.Pos.x + o.Radius * 0.4, o.Height * 0.22, o.Pos.z + o.Radius * 0.3), o.Radius * 0.6, lighting.surf(g, lerpColor(o.Tint, rl.Color.black, 0.15), o.Pos));
}

fn drawGravestone(g: *GameState, o: world.Obstacle) void {
    lighting.drawShadow(g, o.Pos, o.Radius * 1.1);
    const c = lighting.surf(g, o.Tint, o.Pos);
    rl.drawCubeV(v3(o.Pos.x, o.Height / 2, o.Pos.z), v3(o.Radius * 2, o.Height, 0.35), c);
    rl.drawSphere(v3(o.Pos.x, o.Height, o.Pos.z), o.Radius, c);
}

// ---- Player ----

fn drawPlayerBody(g: *GameState) void {
    const p = &g.player;
    if (!p.alive()) return;
    const base = p.Pos;
    const bob = 0.05 * sinf(p.walkBob);
    const f = orFacing(p.Facing, 0, -1);
    const right = perpXZ(f);

    var cloak = rgba(54, 74, 60, 255);
    const hood = rgba(44, 60, 50, 255);
    const skin = rgba(208, 176, 140, 255);

    lighting.drawShadow(g, base, p.Radius * 1.4);

    if (p.rolling()) {
        const tt = p.rollTimer / player.rollDur;
        const low = 0.35 + 0.25 * sinf((1 - tt) * std.math.pi);
        var col = cloak;
        if (p.invulnerable()) col = lerpColor(cloak, rl.Color.white, 0.45);
        rl.drawCapsule(v3(base.x - f.x * 0.2, low, base.z - f.z * 0.2), v3(base.x + f.x * 0.2, low, base.z + f.z * 0.2), 0.42, 12, 8, lighting.surf(g, col, base));
        return;
    }

    const legCol = rgba(40, 40, 46, 255);
    for ([_]f32{ -1, 1 }) |s| {
        const lx = base.x + right.x * 0.18 * s;
        const lz = base.z + right.z * 0.18 * s;
        rl.drawCapsule(v3(lx, 0.08, lz), v3(lx, 0.55 + bob, lz), 0.16, 8, 6, lighting.surf(g, legCol, base));
    }

    if (p.hitFlash > 0) cloak = lerpColor(cloak, rl.Color.white, 0.6);
    rl.drawCapsule(v3(base.x, 0.5 + bob, base.z), v3(base.x, 1.42 + bob, base.z), 0.42, 12, 8, lighting.surf(g, cloak, base));
    rl.drawCapsule(v3(base.x - f.x * 0.22, 0.55 + bob, base.z - f.z * 0.22), v3(base.x - f.x * 0.12, 1.25 + bob, base.z - f.z * 0.12), 0.3, 10, 6, lighting.surf(g, lerpColor(cloak, rl.Color.black, 0.25), base));

    const headPos = v3(base.x, 1.72 + bob, base.z);
    rl.drawSphere(headPos, 0.34, lighting.surf(g, hood, base));
    const facePos = v3(base.x + f.x * 0.22, 1.70 + bob, base.z + f.z * 0.22);
    rl.drawSphere(facePos, 0.2, lighting.surf(g, lerpColor(skin, rl.Color.black, 0.35), base));
    rl.drawCylinderEx(v3(base.x - f.x * 0.1, 1.9 + bob, base.z - f.z * 0.1), v3(base.x - f.x * 0.3, 2.18 + bob, base.z - f.z * 0.3), 0.18, 0.02, 6, lighting.surf(g, hood, base));

    // Bow (wooden, lit) + torch stick (lit). The flame is emissive (pass 2).
    const bowCol = rgba(96, 66, 38, 255);
    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15 + bob, base.z - f.z * 0.18 + right.z * 0.4);
    const topTip = v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18);
    const botTip = v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18);
    rl.drawCylinderEx(bhand, topTip, 0.07, 0.03, 5, lighting.surf(g, bowCol, base));
    rl.drawCylinderEx(bhand, botTip, 0.07, 0.03, 5, lighting.surf(g, bowCol, base));

    const thand = v3(base.x - right.x * 0.45 + f.x * 0.05, 0.95, base.z - right.z * 0.45 + f.z * 0.05);
    const stickTop = v3(thand.x, thand.y + 0.55, thand.z);
    rl.drawCylinderEx(thand, stickTop, 0.05, 0.04, 5, lighting.surf(g, rgba(70, 48, 30, 255), base));
}

fn drawPlayerFX(g: *GameState) void {
    const p = &g.player;
    if (!p.alive()) return;
    const base = p.Pos;
    const f = orFacing(p.Facing, 0, -1);
    const right = perpXZ(f);

    if (p.rolling()) {
        const tt = p.rollTimer / player.rollDur;
        groundRing(v3(base.x, 0.05, base.z), p.Radius + 0.4 * (1 - tt), rgba(200, 210, 230, mathx.u8f(120 * tt)));
        return;
    }

    const bhand = v3(base.x - f.x * 0.18 + right.x * 0.4, 1.15, base.z - f.z * 0.18 + right.z * 0.4);
    const topTip = v3(bhand.x - f.x * 0.18, bhand.y + 0.62, bhand.z - f.z * 0.18);
    const botTip = v3(bhand.x - f.x * 0.18, bhand.y - 0.62, bhand.z - f.z * 0.18);
    rl.drawLine3D(topTip, botTip, lighting.glow(g, rgba(200, 200, 190, 200), base));
    if (p.swing > 0) {
        const sw = p.swing / player.swingDur;
        const reach = 0.7 + sw * 0.9;
        const shoulder = v3(base.x + f.x * 0.3, 1.2, base.z + f.z * 0.3);
        const tip = v3(base.x + f.x * reach, 1.2 + sw * 0.4, base.z + f.z * reach);
        rl.drawCylinderEx(shoulder, tip, 0.07, 0.03, 6, lighting.glow(g, rgba(255, 240, 190, 255), base));
    }

    // Torch flame + rising embers (emissive — the scene's light source).
    const t = g.elapsed;
    const flick = 1 + 0.18 * sinf(t * 22) + 0.1 * sinf(t * 37);
    const thand = v3(base.x - right.x * 0.45 + f.x * 0.05, 0.95, base.z - right.z * 0.45 + f.z * 0.05);
    const flame = v3(thand.x, thand.y + 0.69, thand.z);
    rl.drawSphere(flame, 0.26 * flick, rgba(230, 90, 25, 110));
    rl.drawSphere(flame, 0.17 * flick, rgba(255, 150, 40, 200));
    rl.drawSphere(flame, 0.09 * flick, rgba(255, 235, 150, 255));
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const ph = @mod(t * 0.8 + iff * 0.37, 1.0);
        const drift = 0.14 * sinf(t * 3 + iff);
        const ep = v3(flame.x + drift, flame.y + ph * 0.9, flame.z + drift * 0.5);
        rl.drawSphere(ep, 0.045 * (1 - ph), rgba(255, 160, 60, mathx.u8f((1 - ph) * 170)));
    }

    groundRing(v3(base.x, 0.045, base.z), p.Radius + 0.15, rgba(150, 190, 255, 90));
}

// ---- Monsters ----

const BodyLook = struct { col: rl.Color, alpha: u8, shrink: f32 };

fn monsterBodyColor(m: *const Monster) BodyLook {
    var col = m.Color;
    var alpha: u8 = 255;
    var shrink: f32 = 1;
    if (m.dying) {
        const f = m.deathTimer / monster.monster_death_fade;
        alpha = mathx.u8f(clampF(f * 255, 0, 255));
        shrink = clampF(f, 0.12, 1);
    } else if (m.hitFlash > 0) {
        col = lerpColor(col, rl.Color.white, 0.75);
    } else if (m.windup > 0) {
        const tphase = 1 - m.windup / m.windupTime;
        col = lerpColor(col, rgba(255, 80, 40, 255), 0.35 + 0.45 * tphase);
    }
    return .{ .col = col, .alpha = alpha, .shrink = shrink };
}

fn drawMonsterBodies(g: *GameState) void {
    for (g.monsters.items) |*m| {
        if (!fow.inVision(g, m.Pos)) continue;
        if (distXZ(m.Pos, g.player.Pos) > casterCull) continue;
        if (m.Kind == .fallen) drawFallenBody(g, m) else drawGenericBody(g, m);
    }
}

fn drawMonsterFX(g: *GameState) void {
    for (g.monsters.items, 0..) |*m, i| {
        if (!fow.inVision(g, m.Pos)) continue;
        if (m.Kind == .fallen) drawFallenFX(g, m) else drawGenericFX(g, m);
        drawMonsterTelegraph(g, m);
        drawMonsterMarkers(g, m, @intCast(i));
    }
}

fn drawFallenBody(g: *GameState, m: *Monster) void {
    const look = monsterBodyColor(m);
    const shrink = look.shrink;
    const alpha = look.alpha;
    const x = m.Pos.x;
    const z = m.Pos.z;
    const bob = 0.06 * sinf(m.bob);
    const f = orFacing(m.Facing, 0, 1);
    const right = perpXZ(f);

    if (!m.dying) lighting.drawShadow(g, m.Pos, m.Radius * 1.4);
    const body = withAlpha(lighting.surf(g, look.col, m.Pos), alpha);
    const dark = withAlpha(lighting.surf(g, lerpColor(look.col, rl.Color.black, 0.35), m.Pos), alpha);

    const torsoBot = v3(x - f.x * 0.05, 0.28, z - f.z * 0.05);
    const torsoTop = v3(x + f.x * 0.18, (0.55 + 0.35) * shrink + bob + 0.1, z + f.z * 0.18);
    rl.drawCapsule(torsoBot, torsoTop, m.Radius * 0.85, 10, 6, body);

    const head = v3(x + f.x * 0.28, torsoTop.y + 0.1 * shrink + bob, z + f.z * 0.28);
    rl.drawSphere(head, m.Radius * 0.8 * shrink, body);

    if (shrink > 0.5) {
        for ([_]f32{ -1, 1 }) |s| {
            const b = v3(head.x + right.x * 0.18 * s - f.x * 0.1, head.y + 0.18, head.z + right.z * 0.18 * s - f.z * 0.1);
            const tip = v3(b.x - f.x * 0.18, b.y + 0.28, b.z - f.z * 0.18);
            rl.drawCylinderEx(b, tip, 0.07, 0.0, 5, dark);
        }
        for ([_]f32{ -1, 1 }) |s| {
            const b = v3(head.x + right.x * 0.22 * s, head.y + 0.05, head.z + right.z * 0.22 * s);
            const tip = v3(b.x + right.x * 0.35 * s, b.y + 0.18, b.z + right.z * 0.35 * s);
            rl.drawCylinderEx(b, tip, 0.1, 0.0, 5, dark);
        }
        const hand = v3(x + f.x * 0.45 + right.x * 0.25, 0.6 + bob, z + f.z * 0.45 + right.z * 0.25);
        const tip = v3(hand.x + f.x * 0.3, hand.y + 0.25, hand.z + f.z * 0.3);
        rl.drawCylinderEx(hand, tip, 0.05, 0.01, 4, withAlpha(lighting.surf(g, rgba(150, 155, 165, 255), m.Pos), alpha));
    }
}

fn drawFallenFX(g: *GameState, m: *Monster) void {
    const look = monsterBodyColor(m);
    const shrink = look.shrink;
    if (shrink <= 0.5) return;
    const alpha = look.alpha;
    const x = m.Pos.x;
    const z = m.Pos.z;
    const bob = 0.06 * sinf(m.bob);
    const f = orFacing(m.Facing, 0, 1);
    const right = perpXZ(f);
    const headY = (0.55 + 0.35) * shrink + bob + 0.1 + 0.1 * shrink + bob;
    var eyeCol = rgba(255, 210, 60, 255);
    if (m.windup > 0) eyeCol = rgba(255, 70, 40, 255);
    for ([_]f32{ -1, 1 }) |s| {
        const e = v3(x + f.x * 0.28 + right.x * 0.12 * s, headY + 0.04, z + f.z * 0.28 + right.z * 0.12 * s);
        rl.drawSphere(e, 0.06 * shrink, withAlpha(lighting.glow(g, eyeCol, m.Pos), alpha));
    }
}

fn drawGenericBody(g: *GameState, m: *Monster) void {
    const look = monsterBodyColor(m);
    const shrink = look.shrink;
    const alpha = look.alpha;
    const bob = 0.05 * sinf(m.bob);
    const f = orFacing(m.Facing, 0, 1);
    const right = perpXZ(f);

    if (!m.dying) lighting.drawShadow(g, m.Pos, m.Radius * 1.4);
    const body = withAlpha(lighting.surf(g, look.col, m.Pos), alpha);

    const hbottom: f32 = 0.4;
    const htop = (m.Height - 0.5) * shrink;
    rl.drawCapsule(v3(m.Pos.x, hbottom + bob, m.Pos.z), v3(m.Pos.x, hbottom + htop + bob, m.Pos.z), m.Radius, 10, 6, body);
    const headY = hbottom + htop + 0.25 * shrink + bob;
    rl.drawSphere(v3(m.Pos.x, headY, m.Pos.z), m.Radius * 0.7 * shrink, body);

    if (shrink > 0.5 and m.Ranged) {
        const bowCol = rgba(150, 150, 140, 255);
        const hand = v3(m.Pos.x + right.x * 0.4, 1.1, m.Pos.z + right.z * 0.4);
        const topTip = v3(hand.x, hand.y + 0.6, hand.z);
        const botTip = v3(hand.x, hand.y - 0.6, hand.z);
        rl.drawCylinderEx(hand, topTip, 0.06, 0.02, 4, withAlpha(lighting.surf(g, bowCol, m.Pos), alpha));
        rl.drawCylinderEx(hand, botTip, 0.06, 0.02, 4, withAlpha(lighting.surf(g, bowCol, m.Pos), alpha));
    }
}

fn drawGenericFX(g: *GameState, m: *Monster) void {
    const look = monsterBodyColor(m);
    const shrink = look.shrink;
    if (shrink <= 0.5) return;
    const alpha = look.alpha;
    const bob = 0.05 * sinf(m.bob);
    const f = orFacing(m.Facing, 0, 1);
    const right = perpXZ(f);
    const htop = (m.Height - 0.5) * shrink;
    const headY = 0.4 + htop + 0.25 * shrink + bob;
    var eyeCol = rgba(180, 230, 255, 255);
    if (m.Kind == .brute or m.boss) eyeCol = rgba(255, 120, 60, 255);
    if (m.windup > 0) eyeCol = rgba(255, 70, 40, 255);
    for ([_]f32{ -1, 1 }) |s| {
        const e = v3(m.Pos.x + f.x * m.Radius * 0.5 + right.x * m.Radius * 0.3 * s, headY + 0.02, m.Pos.z + f.z * m.Radius * 0.5 + right.z * m.Radius * 0.3 * s);
        rl.drawSphere(e, 0.07 * shrink, withAlpha(lighting.glow(g, eyeCol, m.Pos), alpha));
    }
}

fn drawMonsterTelegraph(g: *GameState, m: *Monster) void {
    if (m.windup <= 0 or m.dying) return;
    const tphase = 1 - m.windup / m.windupTime;
    const a = mathx.u8f(clampF(110 + 130 * tphase, 0, 255));
    if (m.Ranged) {
        const from = v3(m.Pos.x, 1.2, m.Pos.z);
        const to = v3(g.player.Pos.x, 0.3, g.player.Pos.z);
        rl.drawCylinderEx(from, to, 0.05, 0.05, 4, rgba(255, 70, 50, a));
    } else {
        const rr = m.atkRange + g.player.Radius;
        groundRing(v3(m.Pos.x, 0.09, m.Pos.z), rr, rgba(255, 60, 40, a));
        groundRing(v3(m.Pos.x, 0.09, m.Pos.z), rr * tphase, rgba(255, 100, 50, a));
    }
}

fn drawMonsterMarkers(g: *GameState, m: *Monster, idx: i32) void {
    if (m.dying) return;
    if (m.boss) {
        groundRing(v3(m.Pos.x, 0.06, m.Pos.z), m.Radius + 0.4, rgba(255, 60, 60, 200));
    }
    if (idx == g.hoverMonster) {
        groundRing(v3(m.Pos.x, 0.07, m.Pos.z), m.Radius + 0.25, rgba(255, 230, 120, 220));
    }
}

// ---- Loot / portal / projectiles (emissive) ----

fn drawLoot(g: *GameState) void {
    for (g.loot.items) |*d| {
        if (!fow.inVision(g, d.Pos)) continue;
        const y = 0.4 + 0.12 * sinf(d.bob);
        lighting.drawShadow(g, d.Pos, 0.35);
        switch (d.Kind) {
            .gold => rl.drawSphere(v3(d.Pos.x, y * 0.6, d.Pos.z), 0.26, lighting.glow(g, rgba(255, 205, 60, 255), d.Pos)),
            .health_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), lighting.glow(g, rgba(220, 40, 50, 255), d.Pos)),
            .mana_potion => rl.drawCubeV(v3(d.Pos.x, y, d.Pos.z), v3(0.4, 0.6, 0.4), lighting.glow(g, rgba(60, 110, 235, 255), d.Pos)),
        }
    }
}

fn drawPortal(g: *GameState) void {
    const p = g.world.PortalPos;
    if (!g.world.PortalOpen) {
        rl.drawCylinderEx(v3(p.x, 0.02, p.z), v3(p.x, 0.05, p.z), 2.0, 2.0, 24, lighting.glow(g, rgba(60, 60, 80, 200), p));
        return;
    }
    const t = g.elapsed;
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const yy = iff * 0.7;
        const r = 1.7 - iff * 0.16 + 0.15 * sinf(t * 3 + iff);
        const c = lerpColor(rgba(90, 120, 255, 210), rgba(190, 120, 255, 170), iff / 6);
        rl.drawCylinderEx(v3(p.x, yy, p.z), v3(p.x, yy + 0.7, p.z), r, r * 0.8, 22, lighting.glow(g, c, p));
    }
    groundRing(v3(p.x, 0.06, p.z), 2.0 + 0.2 * sinf(t * 4), lighting.glow(g, rgba(150, 180, 255, 255), p));
}

fn drawProjectiles(g: *GameState) void {
    for (g.projectiles.items) |*pr| {
        const c = lighting.glow(g, pr.Color, pr.Pos);
        rl.drawSphere(pr.Pos, pr.Radius, c);
        const tail = v3(pr.Pos.x - pr.Vel.x * 0.03, pr.Pos.y, pr.Pos.z - pr.Vel.z * 0.03);
        rl.drawCylinderEx(tail, pr.Pos, pr.Radius * 0.3, pr.Radius, 6, withAlpha(c, 130));
    }
}
