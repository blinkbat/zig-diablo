const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const gamemod = @import("game.zig");
const playermod = @import("player.zig");
const monster = @import("monster.zig");
const theme = @import("theme.zig");

const Game = gamemod.Game;
const Player = playermod.Player;
const rgba = mathx.rgba;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;
const lerpColor = mathx.lerpColor;
const sinf = mathx.sinf;
const v3 = mathx.v3;

// HUD + world overlays + scene screens for the game (game.zig). 2D only — drawn after
// endMode3D, so it never touches the torch lighting.

// Height (px) of the bottom band the HUD occupies (orbs, belt, XP bar). The single
// source of truth for how tall the HUD is; game.zig reads it to ignore world clicks
// that land on the HUD, so the two can't drift apart.
pub const bottomBandHeight: i32 = 140;

fn sw() i32 {
    return rl.getScreenWidth();
}
fn sh() i32 {
    return rl.getScreenHeight();
}

fn fi(v: i32) f32 {
    return @floatFromInt(v);
}

// Text with a 2px drop shadow for legibility over the 3D scene.
fn text(s: [:0]const u8, x: i32, y: i32, size: i32, col: rl.Color) void {
    rl.drawText(s, x + 2, y + 2, size, rgba(0, 0, 0, 200));
    rl.drawText(s, x, y, size, col);
}
fn centered(s: [:0]const u8, cy: i32, size: i32, col: rl.Color) void {
    const w = rl.measureText(s, size);
    text(s, @divTrunc(sw(), 2) - @divTrunc(w, 2), cy, size, col);
}

// Big display text with a warm halo behind it — the closest a bitmap font gets to a
// glow. The halo is the text redrawn at the four diagonals in a low-alpha ember tone.
fn glowCentered(s: [:0]const u8, cy: i32, size: i32, col: rl.Color, halo: rl.Color) void {
    const w = rl.measureText(s, size);
    const x = @divTrunc(sw(), 2) - @divTrunc(w, 2);
    for ([_][2]i32{ .{ -3, -3 }, .{ 3, -3 }, .{ -3, 3 }, .{ 3, 3 } }) |off| {
        rl.drawText(s, x + off[0], cy + off[1], size, halo);
    }
    rl.drawText(s, x + 3, cy + 4, size, rgba(0, 0, 0, 220));
    rl.drawText(s, x, cy, size, col);
}

// A soft rounded backing pill behind free-floating text.
fn pill(x: i32, y: i32, w: i32, h: i32, col: rl.Color) void {
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y), .width = fi(w), .height = fi(h) }, 0.9, 8, col);
}

// Top-level dispatcher: called once per frame after the 3D pass.
pub fn draw(g: *Game, cam: rl.Camera3D) void {
    switch (g.scene) {
        .menu => {
            vignette();
            drawMenu(g.elapsed);
        },
        .playing => {
            drawWorldOverlays(g, cam);
            vignette();
            drawHUD(g);
            if (g.paused) drawPauseOverlay();
        },
        .dead => {
            drawWorldOverlays(g, cam);
            vignette();
            drawHUD(g);
            drawDeath(g);
        },
        .victory => {
            vignette();
            drawVictory(g);
        },
    }
}

// A world-to-screen projection is safe to draw only if it's finite AND within a sane
// pixel range: getWorldToScreen can return huge finite values for points near the
// camera plane, which would overflow the i32 casts these overlays feed it into.
fn projValid(sp: rl.Vector2) bool {
    return std.math.isFinite(sp.x) and std.math.isFinite(sp.y) and @abs(sp.x) < 1.0e6 and @abs(sp.y) < 1.0e6;
}

// Which foe owns the top-center plate this frame: the one under the cursor first,
// else the one the hero is attacking, else an aggro'd champion in vision — so a boss
// fight keeps its bar up even while the cursor wanders.
fn pickEnemyPlate(g: *Game) ?*const monster.Monster {
    if (g.monsterByID(g.hoverMonster)) |m| {
        if (m.alive() and g.inVision(m.Pos)) return m;
    }
    if (g.monsterByID(g.p.targetMonster)) |m| {
        if (m.alive() and g.inVision(m.Pos)) return m;
    }
    for (g.liveMonsters()) |*m| {
        if (m.boss and m.alive() and m.aggro and g.inVision(m.Pos)) return m;
    }
    return null;
}

// Top-center enemy plate, PoE/D2 style: the foe's name over one wide thin bar at the
// top of the screen — never floating bars over heads cluttering the battlefield.
fn drawEnemyPlate(g: *Game) void {
    const m = pickEnemyPlate(g) orelse return;
    const W = sw();
    const boss = m.boss;
    const bw: i32 = if (boss) 420 else 300;
    const bh: i32 = if (boss) 12 else 8;
    const size: i32 = if (boss) 22 else 18;
    const cx = @divTrunc(W, 2);
    const bx = cx - @divTrunc(bw, 2);
    const by = 16 + size + 6;
    // One soft backing behind name + bar so both read over any scene.
    pill(bx - 18, 8, bw + 36, by - 8 + bh + 10, rgba(8, 6, 5, 165));
    var nbuf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&nbuf, "{s}", .{m.Name}) catch "";
    centered(name, 14, size, if (boss) rgba(255, 185, 205, 255) else rgba(240, 225, 205, 255));
    rl.drawRectangle(bx - 2, by - 2, bw + 4, bh + 4, rgba(8, 6, 5, 235));
    const fillCol = if (boss) rgba(225, 45, 105, 255) else rgba(200, 48, 40, 255);
    const frac = clampF(m.HP / m.MaxHP, 0, 1);
    const fw: i32 = @intFromFloat(fi(bw) * frac);
    if (fw > 0) {
        rl.drawRectangleGradientH(bx, by, fw, bh, lerpColor(fillCol, rl.Color.black, 0.3), fillCol);
        rl.drawRectangle(bx, by, fw, 2, withAlpha(lerpColor(fillCol, rl.Color.white, 0.5), 210));
    }
    // Quarter ticks + a thin brass frame: the PoE signature of a "measured" bar.
    var q: i32 = 1;
    while (q < 4) : (q += 1) {
        rl.drawRectangle(bx + @divTrunc(bw * q, 4), by, 1, bh, rgba(8, 6, 5, 170));
    }
    rl.drawRectangleLines(bx - 2, by - 2, bw + 4, bh + 4, withAlpha(theme.trimColor, 140));
}

// Floating combat text, projected from world to screen. (Enemy health lives on the
// top-center plate — drawEnemyPlate — not over heads.)
fn drawWorldOverlays(g: *Game, cam: rl.Camera3D) void {
    // Floating combat text (hidden when its source sits in darkness).
    for (g.popups.items) |*pp| {
        if (!g.inVision(pp.Pos)) continue;
        const sp = rl.getWorldToScreen(pp.Pos, cam);
        if (!projValid(sp)) continue;
        const a = mathx.u8f(clampF(pp.Life / pp.maxLife * 255, 0, 255));
        var tbuf: [gamemod.POPUP_TEXT_CAP + 1]u8 = undefined; // +1 for bufPrintZ's sentinel
        const txt = std.fmt.bufPrintZ(&tbuf, "{s}", .{pp.text()}) catch "";
        const w = rl.measureText(txt, 20);
        rl.drawText(txt, @as(i32, @intFromFloat(sp.x)) - @divTrunc(w, 2) + 1, @as(i32, @intFromFloat(sp.y)) + 1, 20, rgba(0, 0, 0, a));
        rl.drawText(txt, @as(i32, @intFromFloat(sp.x)) - @divTrunc(w, 2), @as(i32, @intFromFloat(sp.y)), 20, withAlpha(pp.Color, a));
    }
}

// ---- 3D liquid orbs ----
// Each orb is a REAL lit 3D scene rendered offscreen once per frame: a sphere mesh
// shaded by its own little shader — N-dot-L liquid whose fill plane is clipped IN
// THE SHADER (the cut line laps around the glass wall), a true elliptical meniscus
// disc under a perspective camera, rising bubbles, and a fresnel glass shell with a
// hard specular window — composited into the iron socket. One shared RT + sphere
// mesh + shader serves both orbs.

const ORB_RT_SIZE = 256;
const ORB_R = 0.95;

const orbVS =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec3 vertexNormal;
    \\uniform mat4 mvp;
    \\uniform mat4 matModel;
    \\out vec3 fragPosition;
    \\out vec3 fragNormal;
    \\void main() {
    \\    fragPosition = vec3(matModel*vec4(vertexPosition, 1.0));
    \\    fragNormal = mat3(matModel)*vertexNormal;
    \\    gl_Position = mvp*vec4(vertexPosition, 1.0);
    \\}
;
const orbFS =
    \\#version 330
    \\in vec3 fragPosition;
    \\in vec3 fragNormal;
    \\uniform vec4 liquidColor;
    \\uniform float fillY;   // liquid plane; mode-0 fragments above it are discarded
    \\uniform int mode;      // 0 = liquid volume, 1 = glass shell
    \\uniform float time;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec3 N = normalize(fragNormal);
    \\    vec3 L = normalize(vec3(-0.45, 0.8, 0.65));
    \\    vec3 V = normalize(vec3(0.0, 0.9, 4.3) - fragPosition);
    \\    if (mode == 0) {
    \\        // The fill line laps gently around the glass wall on two beats.
    \\        float ang = atan(fragPosition.x, fragPosition.z);
    \\        float lap = 0.02*sin(6.0*ang + time*2.4) + 0.008*sin(11.0*ang - time*3.1);
    \\        if (fragPosition.y > fillY + lap) discard;
    \\        float nl = max(dot(N, L), 0.0);
    \\        vec3 col = liquidColor.rgb*(0.30 + 0.70*nl);
    \\        // Depth grade: dark at the bowl's bottom, lit just under the surface.
    \\        col *= mix(0.68, 1.18, smoothstep(-1.0, 0.6, fragPosition.y));
    \\        float spec = pow(max(dot(reflect(-L, N), V), 0.0), 28.0);
    \\        finalColor = vec4(col + vec3(0.45)*spec, 1.0);
    \\    } else {
    \\        // Glass: fresnel rim + a hard specular window; transparent elsewhere.
    \\        float fres = pow(1.0 - max(dot(N, V), 0.0), 3.0);
    \\        float spec = pow(max(dot(reflect(-L, N), V), 0.0), 70.0);
    \\        float a = clamp(fres*0.5 + spec*0.95, 0.0, 1.0);
    \\        finalColor = vec4(vec3(0.75, 0.85, 1.0)*fres*0.6 + vec3(1.0)*spec, a);
    \\    }
    \\}
;

var orbRT: ?rl.RenderTexture2D = null;
var orbShader: rl.Shader = undefined;
var orbMesh: rl.Mesh = undefined;
var orbMat: rl.Material = undefined;
var orbLocLiquid: i32 = 0;
var orbLocFill: i32 = 0;
var orbLocMode: i32 = 0;
var orbLocTime: i32 = 0;

fn ensureOrbAssets() ?rl.RenderTexture2D {
    if (orbRT == null) {
        const rt = rl.loadRenderTexture(ORB_RT_SIZE, ORB_RT_SIZE) catch return null;
        const shd = rl.loadShaderFromMemory(orbVS, orbFS) catch {
            rl.unloadRenderTexture(rt);
            return null;
        };
        rl.setTextureFilter(rt.texture, .bilinear);
        orbShader = shd;
        orbLocLiquid = rl.getShaderLocation(shd, "liquidColor");
        orbLocFill = rl.getShaderLocation(shd, "fillY");
        orbLocMode = rl.getShaderLocation(shd, "mode");
        orbLocTime = rl.getShaderLocation(shd, "time");
        orbMesh = rl.genMeshSphere(ORB_R, 32, 32);
        orbMat = rl.loadMaterialDefault() catch {
            rl.unloadShader(shd);
            rl.unloadMesh(orbMesh);
            rl.unloadRenderTexture(rt);
            return null;
        };
        orbMat.shader = orbShader;
        orbRT = rt;
    }
    return orbRT;
}

// Called from Game.deinit so the GPU assets don't outlive the GL context. The
// material only wraps orbShader (freed here); its tiny default-map array is left to
// the OS rather than risk a double-free — same policy as SceneMesh.
pub fn unloadOrbRT() void {
    if (orbRT) |rt| {
        rl.unloadRenderTexture(rt);
        rl.unloadShader(orbShader);
        rl.unloadMesh(orbMesh);
    }
    orbRT = null;
}

fn setOrbLiquid(c: rl.Color) void {
    const v = [4]f32{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
        1.0,
    };
    rl.setShaderValue(orbShader, orbLocLiquid, &v, .vec4);
}

fn renderOrbScene(rt: rl.RenderTexture2D, frac: f32, full: rl.Color, empty: rl.Color, t: f32, phase: f32) void {
    const cam = rl.Camera3D{
        .position = v3(0, 0.9, 4.3), // matches the hardcoded V in orbFS
        .target = v3(0, 0, 0),
        .up = v3(0, 1, 0),
        .fovy = 26.0,
        .projection = .perspective,
    };
    const yl = -ORB_R + frac * ORB_R * 2; // liquid plane height
    const chord = @sqrt(@max(ORB_R * ORB_R - yl * yl, 0.0)); // surface radius there

    rl.beginTextureMode(rt);
    rl.clearBackground(rl.Color.blank);
    rl.beginMode3D(cam);

    rl.setShaderValue(orbShader, orbLocTime, &t, .float);

    // Drained interior: the same lit shader pouring a near-black liquid to the brim,
    // slightly shrunken so the real liquid shell wins the depth test over it.
    var mode: i32 = 0;
    var fill: f32 = 2.0;
    rl.setShaderValue(orbShader, orbLocMode, &mode, .int);
    rl.setShaderValue(orbShader, orbLocFill, &fill, .float);
    setOrbLiquid(empty);
    rl.drawMesh(orbMesh, orbMat, rl.math.matrixScale(0.985, 0.985, 0.985));

    if (frac > 0.004) {
        fill = yl;
        rl.setShaderValue(orbShader, orbLocFill, &fill, .float);
        setOrbLiquid(full);
        rl.drawMesh(orbMesh, orbMat, rl.math.matrixIdentity());

        // Surface + bubbles read THROUGH the front of the liquid: painter's order.
        rl.gl.rlDisableDepthTest();
        if (frac < 0.996) {
            rl.drawCylinderEx(v3(0, yl - 0.015, 0), v3(0, yl + 0.015, 0), chord * 0.99, chord * 0.99, 32, lerpColor(full, rl.Color.white, 0.30));
            rl.drawCircle3D(v3(0, yl + 0.025, 0), chord * 0.99, v3(1, 0, 0), 90, withAlpha(lerpColor(full, rl.Color.white, 0.7), 235));
        }
        var bi: i32 = 0;
        while (bi < 4) : (bi += 1) {
            const bf = fi(bi);
            const ph = @mod(t * (0.22 + bf * 0.07) + bf * 0.37 + phase, 1.0);
            const by = -0.8 + ph * (yl + 0.72);
            if (by < yl - 0.06) {
                const bx = sinf(t * 0.7 + phase + bf * 2.6) * 0.38;
                rl.drawSphereEx(v3(bx, by, 0.5), 0.028 + bf * 0.012 + ph * 0.02, 8, 8, withAlpha(lerpColor(full, rl.Color.white, 0.55), 160));
            }
        }
        rl.gl.rlEnableDepthTest();
    }

    // Fresnel glass shell over everything.
    rl.gl.rlDisableDepthTest();
    mode = 1;
    rl.setShaderValue(orbShader, orbLocMode, &mode, .int);
    rl.drawMesh(orbMesh, orbMat, rl.math.matrixIdentity());
    rl.gl.rlEnableDepthTest();

    rl.endMode3D();
    rl.endTextureMode();
}

// A liquid-filled glass globe in an iron-and-brass socket, rendered as a real 3D
// scene (renderOrbScene) and composited here. Pulses an alarm glow when low.
fn drawOrb(cx: i32, cy: i32, radius: i32, frac_in: f32, full: rl.Color, empty: rl.Color, t: f32) void {
    const frac = clampF(frac_in, 0, 1);
    const rf = fi(radius);

    // Low-resource alarm: a soft pulsing halo outside the socket.
    if (frac < 0.28) {
        const pa = mathx.u8f(50 + 45 * sinf(t * 6));
        rl.drawCircle(cx, cy, rf + 9, withAlpha(lerpColor(full, rl.Color.white, 0.15), pa));
    }

    rl.drawCircle(cx, cy, rf + 5, rgba(8, 6, 5, 235));

    if (ensureOrbAssets()) |rt| {
        renderOrbScene(rt, frac, full, empty, t, fi(cx) * 0.017);
        // Scale so the sphere's projected radius (~123 px of the 256 RT under the
        // 26-degree camera) lands exactly on the socket rim.
        const S = rf * 2.09 + 2;
        rl.drawTexturePro(
            rt.texture,
            .{ .x = 0, .y = 0, .width = ORB_RT_SIZE, .height = -ORB_RT_SIZE },
            .{ .x = fi(cx) - S / 2, .y = fi(cy) - S / 2, .width = S, .height = S },
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
    } else {
        // Render-target fallback: a flat fill so the HUD still reports the resource.
        rl.drawCircle(cx, cy, rf, empty);
        const fillH: i32 = @intFromFloat(fi(radius * 2) * frac);
        if (fillH > 0) {
            rl.beginScissorMode(cx - radius, cy + radius - fillH, radius * 2, fillH);
            rl.drawCircle(cx, cy, rf, full);
            rl.endScissorMode();
        }
    }

    // Socket: heavy iron ring with a thin brass liner.
    const cv = rl.Vector2.init(fi(cx), fi(cy));
    rl.drawRing(cv, rf, rf + 5, 0, 360, 48, rgba(32, 26, 20, 255));
    rl.drawRing(cv, rf + 4, rf + 5.5, 0, 360, 48, theme.trimColor);
    rl.drawRing(cv, rf - 1, rf + 1, 0, 360, 48, rgba(15, 12, 10, 255));
}

fn drawHUD(g: *Game) void {
    const p = &g.p;
    const W = sw();
    const H = sh();
    const t = g.elapsed;

    // Damage flash: red pain closing in from the screen edges, not a flat wash.
    if (g.damageFlash > 0) {
        const k = clampF(g.damageFlash / gamemod.DAMAGE_FLASH_DUR, 0, 1);
        const cx = @divTrunc(W, 2);
        const cy = @divTrunc(H, 2);
        const r = @sqrt(fi(cx * cx + cy * cy)) * (1.25 - 0.15 * k);
        rl.drawCircleGradient(cx, cy, r, rgba(180, 0, 0, 0), rgba(190, 10, 10, mathx.u8f(200 * k)));
    }

    // One fixed-width command cluster, centered on the bottom edge: the two orbs
    // bracket a single bound panel (flasks, dodge, gold, XP channel), so combat
    // vitals live in ONE gaze instead of splitting your vision across the corners.
    const hudW: i32 = @min(W - 24, 840);
    const hudX = @divTrunc(W - hudW, 2);
    const orbR: i32 = 56;
    const orbY = H - orbR - 22;
    const healthCX = hudX + orbR + 4;
    const manaCX = hudX + hudW - orbR - 4;

    drawOrb(healthCX, orbY, orbR, p.HP / p.MaxHP, theme.healthColor, theme.healthSocket, t);
    var b1: [64]u8 = undefined;
    const hp = std.fmt.bufPrintZ(&b1, "{d}/{d}", .{ @as(i32, @intFromFloat(p.HP)), @as(i32, @intFromFloat(p.MaxHP)) }) catch "";
    text(hp, healthCX - @divTrunc(rl.measureText(hp, 16), 2), orbY - 8, 16, rl.Color.white);

    drawOrb(manaCX, orbY, orbR, p.Mana / p.MaxMana, theme.manaColor, theme.manaSocket, t);
    var b2: [64]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&b2, "{d}/{d}", .{ @as(i32, @intFromFloat(p.Mana)), @as(i32, @intFromFloat(p.MaxMana)) }) catch "";
    text(mp, manaCX - @divTrunc(rl.measureText(mp, 16), 2), orbY - 8, 16, rl.Color.white);

    // XP: a burnished-gold channel spanning orb to orb, notched at each tenth, with
    // a slow light sweep over the fill.
    const xpX = healthCX + orbR + 18;
    const xpW = manaCX - orbR - 18 - xpX;
    const xpY = H - 24;
    const frac = if (p.XPNext > 0) @as(f32, @floatFromInt(p.XP)) / @as(f32, @floatFromInt(p.XPNext)) else 0;
    rl.drawRectangle(xpX - 2, xpY - 2, xpW + 4, 12, rgba(8, 6, 5, 235));
    rl.drawRectangle(xpX, xpY, xpW, 8, rgba(28, 22, 14, 255));
    const fw: i32 = @intFromFloat(fi(xpW) * clampF(frac, 0, 1));
    if (fw > 0) {
        rl.drawRectangleGradientH(xpX, xpY, fw, 8, rgba(140, 100, 30, 255), theme.goldColor);
        rl.drawRectangle(xpX, xpY, fw, 2, withAlpha(rgba(255, 245, 190, 255), 190));
        const sweepW: i32 = 44;
        const sx = xpX - sweepW + @as(i32, @intFromFloat(@mod(t * 90.0, fi(fw + sweepW * 2))));
        rl.beginScissorMode(xpX, xpY, fw, 8);
        rl.drawRectangleGradientH(sx, xpY, sweepW, 8, withAlpha(rl.Color.white, 0), withAlpha(rl.Color.white, 55));
        rl.drawRectangleGradientH(sx + sweepW, xpY, sweepW, 8, withAlpha(rl.Color.white, 55), withAlpha(rl.Color.white, 0));
        rl.endScissorMode();
    }
    var tick: i32 = 1;
    while (tick < 10) : (tick += 1) {
        rl.drawRectangle(xpX + @divTrunc(xpW * tick, 10), xpY, 1, 8, rgba(8, 6, 5, 170));
    }
    rl.drawRectangleLines(xpX - 2, xpY - 2, xpW + 4, 12, withAlpha(theme.trimColor, 110));

    var b3: [32]u8 = undefined;
    const lvl = std.fmt.bufPrintZ(&b3, "Level {d}", .{p.Level}) catch "";
    text(lvl, @divTrunc(W, 2) - @divTrunc(rl.measureText(lvl, 14), 2), H - 42, 14, rgba(235, 210, 150, 220));

    drawBelt(p, @divTrunc(W, 2), H - 58);

    // Dodge readiness: an arc that sweeps back around as the roll recharges, then
    // settles to a steady bright ring when the escape is available again.
    const dodgeC = rl.Vector2.init(fi(@divTrunc(W, 2)), fi(H - 90));
    rl.drawRing(dodgeC, 5, 8, 0, 360, 24, rgba(30, 30, 38, 220));
    if (p.rollCD > 0) {
        const done = 1 - clampF(p.rollCD / playermod.rollCDMax, 0, 1);
        rl.drawRing(dodgeC, 5, 8, -90, -90 + 360 * done, 24, rgba(110, 150, 200, 220));
    } else {
        rl.drawRing(dodgeC, 5, 8, 0, 360, 24, rgba(160, 210, 255, 240));
        rl.drawRing(dodgeC, 3, 5, 0, 360, 24, withAlpha(rgba(160, 210, 255, 255), mathx.u8f(60 + 40 * sinf(t * 4))));
    }

    drawTopRight(g);
    drawEnemyPlate(g);

    // Transient status toast (top-center pill, tucked under the enemy plate zone).
    if (g.toast.active()) {
        const a = mathx.u8f(clampF(g.toast.time / gamemod.TOAST_DUR * 255, 0, 255));
        const tw = rl.measureText(g.toast.text(), 22);
        pill(@divTrunc(W, 2) - @divTrunc(tw, 2) - 16, 78, tw + 32, 36, rgba(8, 6, 5, @intFromFloat(fi(a) * 0.55)));
        centered(g.toast.text(), 84, 22, withAlpha(rgba(255, 245, 210, 255), a));
    }

    // Area-name banner: big glowing title flanked by fading gold rules.
    if (g.banner.active()) {
        const a = clampF(g.banner.time, 0, 1);
        const a8 = mathx.u8f(a * 255);
        const by = @divTrunc(H, 3);
        const bw = rl.measureText(g.banner.text(), 56);
        const ruleY = by + 30;
        const ruleW: i32 = 150;
        const gapL = @divTrunc(W, 2) - @divTrunc(bw, 2) - 24;
        const gapR = @divTrunc(W, 2) + @divTrunc(bw, 2) + 24;
        rl.drawRectangleGradientH(gapL - ruleW, ruleY, ruleW, 2, withAlpha(theme.goldColor, 0), withAlpha(theme.goldColor, a8));
        rl.drawRectangleGradientH(gapR, ruleY, ruleW, 2, withAlpha(theme.goldColor, a8), withAlpha(theme.goldColor, 0));
        glowCentered(g.banner.text(), by, 56, withAlpha(rgba(255, 225, 160, 255), a8), withAlpha(rgba(160, 70, 20, 255), @intFromFloat(fi(a8) * 0.35)));
    }
}

// A little corked flask icon (bulb + neck + shine), used by the belt slots.
fn flaskIcon(x: i32, y: i32, col: rl.Color) void {
    rl.drawRectangle(x + 4, y + 2, 6, 5, rgba(24, 20, 16, 255)); // neck
    rl.drawRectangle(x + 3, y, 8, 3, rgba(150, 112, 70, 255)); // cork
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y + 6), .width = 14, .height = 13 }, 0.7, 6, lerpColor(col, rl.Color.black, 0.25));
    rl.drawRectangleRounded(.{ .x = fi(x + 2), .y = fi(y + 8), .width = 10, .height = 9 }, 0.7, 6, col);
    rl.drawRectangle(x + 3, y + 9, 2, 5, withAlpha(rl.Color.white, 90)); // glass shine
}

// A framed belt slot (PoE-style socket): dark well, brass liner, flask, count badge,
// and its hotkey on a little key chip above. Greys out when the belt runs dry.
fn flaskSlot(x: i32, y: i32, col: rl.Color, count: i32, key: [:0]const u8) void {
    const have = count > 0;
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y), .width = 30, .height = 36 }, 0.3, 6, rgba(12, 9, 8, 215));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x), .y = fi(y), .width = 30, .height = 36 }, 0.3, 6, 1, withAlpha(theme.trimColor, if (have) 170 else 70));
    flaskIcon(x + 8, y + 5, if (have) col else lerpColor(col, rgba(40, 40, 44, 255), 0.75));
    // Count badge, bottom-right of the well.
    var cb: [8]u8 = undefined;
    const ct = std.fmt.bufPrintZ(&cb, "{d}", .{count}) catch "";
    text(ct, x + 28 - rl.measureText(ct, 14), y + 22, 14, if (have) rl.Color.white else rgba(140, 130, 125, 200));
    // Hotkey chip.
    rl.drawRectangleRounded(.{ .x = fi(x + 8), .y = fi(y - 16), .width = 14, .height = 14 }, 0.3, 4, rgba(14, 11, 9, 220));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x + 8), .y = fi(y - 16), .width = 14, .height = 14 }, 0.3, 4, 1, withAlpha(theme.trimColor, 140));
    rl.drawText(key, x + 12, y - 14, 10, rgba(215, 195, 160, 235));
}

// The centered belt cluster: two flask slots flanking the gold purse readout.
fn drawBelt(p: *const Player, cx: i32, y: i32) void {
    var b3: [24]u8 = undefined;
    const goldTxt = std.fmt.bufPrintZ(&b3, "{d} g", .{p.Gold}) catch "";
    flaskSlot(cx - 76, y - 18, theme.healthColor, p.HealthPots, "1");
    flaskSlot(cx + 46, y - 18, theme.manaColor, p.ManaPots, "2");
    text(goldTxt, cx - @divTrunc(rl.measureText(goldTxt, 16), 2), y, 16, theme.goldColor);
}

// Top-right iron plaque: the enemy count behind a little skull pip, with the
// FPS / frame-time / object readout tucked small and grey beneath it — one framed
// corner instead of two lines of bare debug text floating over the world.
fn drawTopRight(g: *Game) void {
    const W = sw();
    var b1: [32]u8 = undefined;
    const en = std.fmt.bufPrintZ(&b1, "{d}", .{g.remainingMonsters()}) catch "";
    var b2: [64]u8 = undefined;
    const perf = std.fmt.bufPrintZ(&b2, "FPS {d}  {d:.1} ms  {d} obj", .{ rl.getFPS(), rl.getFrameTime() * 1000, g.objectCount() }) catch "";
    const w = @max(rl.measureText(en, 22) + 46, rl.measureText(perf, 12) + 24);
    const x = W - w - 10;
    pill(x, 8, w, 50, rgba(8, 6, 5, 175));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x), .y = 8, .width = fi(w), .height = 50 }, 0.9, 8, 1, withAlpha(theme.trimColor, 110));
    // Skull pip: cranium, hanging jaw, hollow sockets.
    const px = x + 14;
    const bone = rgba(222, 208, 188, 255);
    rl.drawCircle(px + 6, 22, 6, bone);
    rl.drawRectangle(px + 3, 26, 7, 4, bone);
    rl.drawCircle(px + 4, 22, 2, rgba(26, 10, 10, 255));
    rl.drawCircle(px + 9, 22, 2, rgba(26, 10, 10, 255));
    text(en, px + 20, 12, 22, rgba(255, 205, 195, 245));
    text(perf, x + 12, 38, 12, rgba(150, 175, 150, 150));
}

// Edge vignette so the eye stays on the lit center.
fn vignette() void {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    const r = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.02;
    rl.drawCircleGradient(cx, cy, r, rgba(0, 0, 0, 0), rgba(0, 0, 0, 150));
}

// A stateless field of drifting screen embers: each mote's path is a pure function of
// time and its index, so the scene screens get living air with zero bookkeeping.
// `upward` embers rise (menu, death); otherwise they fall like gold rain (victory).
fn emberField(t: f32, n: i32, col: rl.Color, upward: bool) void {
    const W = fi(sw());
    const H = fi(sh());
    const baseA: f32 = @floatFromInt(col.a);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const speed = 0.03 + 0.05 * @mod(iff * 0.377, 1.0);
        const ph = @mod(t * speed + iff * 0.171, 1.0);
        const x = @mod(iff * 0.618, 1.0) * W + sinf(t * 0.6 + iff * 1.3) * 30;
        const y = if (upward) H * (1.06 - ph * 1.12) else H * (ph * 1.12 - 0.06);
        const a = mathx.u8f(baseA * (1 - ph) * (0.55 + 0.45 * sinf(t * 2.5 + iff * 2.1)));
        rl.drawCircleV(.{ .x = x, .y = y }, 1.2 + @mod(iff, 3.0) * 0.8, withAlpha(col, a));
    }
}

fn drawPauseOverlay() void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 150));
    glowCentered("PAUSED", @divTrunc(sh(), 2) - 30, 60, rl.Color.white, rgba(60, 60, 90, 90));
    centered("Press P to resume", @divTrunc(sh(), 2) + 40, 24, rgba(220, 220, 220, 255));
}

fn drawMenu(t: f32) void {
    const W = sw();
    const H = sh();
    rl.drawRectangle(0, 0, W, H, rgba(4, 3, 6, 175));
    emberField(t, 22, rgba(255, 140, 50, 200), true);

    // A smoldering backglow breathes behind the title.
    rl.drawCircleGradient(@divTrunc(W, 2), @divTrunc(H, 2) - 125, 320, rgba(120, 16, 8, mathx.u8f(60 + 25 * sinf(t * 1.8))), rgba(120, 16, 8, 0));
    glowCentered("GO DIABLO", @divTrunc(H, 2) - 170, 90, rgba(210, 45, 40, 255), withAlpha(rgba(90, 8, 8, 255), mathx.u8f(95 + 35 * sinf(t * 1.8))));
    // Gold rule under the title.
    const ruleW: i32 = 340;
    rl.drawRectangleGradientH(@divTrunc(W, 2) - ruleW, @divTrunc(H, 2) - 66, ruleW, 2, withAlpha(theme.goldColor, 0), theme.goldColor);
    rl.drawRectangleGradientH(@divTrunc(W, 2), @divTrunc(H, 2) - 66, ruleW, 2, theme.goldColor, withAlpha(theme.goldColor, 0));
    centered("A Diablo II-style action RPG", @divTrunc(H, 2) - 52, 26, rgba(220, 200, 180, 255));

    const enterA = mathx.u8f(200 + 55 * sinf(t * 2.5));
    centered("Press ENTER to descend", @divTrunc(H, 2) + 16, 32, withAlpha(rgba(255, 230, 160, 255), enterA));

    // Controls + creed, on a soft panel so they read over the drifting scene.
    const panelW: i32 = 820;
    const panelY = @divTrunc(H, 2) + 68;
    const panelH: i32 = 292;
    rl.drawRectangleRounded(.{ .x = fi(@divTrunc(W, 2) - @divTrunc(panelW, 2)), .y = fi(panelY), .width = fi(panelW), .height = fi(panelH) }, 0.08, 8, rgba(8, 6, 10, 170));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(@divTrunc(W, 2) - @divTrunc(panelW, 2)), .y = fi(panelY), .width = fi(panelW), .height = fi(panelH) }, 0.08, 8, 1, withAlpha(theme.trimColor, 120));

    const lines = [_][:0]const u8{
        "Left mouse  -  move, or attack the monster under the cursor",
        "Right mouse -  cast Firebolt toward the cursor (uses mana)",
        "Spacebar    -  dodge roll (brief invulnerability) - your lifeline",
        "1 / 2       -  drink Health / Mana potion",
        "Mouse wheel -  zoom    |    P - pause    |    Esc - menu",
        "Gamepad: L-stick move  -  R-stick aim  -  X hit  Y firebolt  B dodge  -  L1/R1 potions  -  Start menu",
        "",
        "This world is slow, methodical, and deadly. Blows are heavy and",
        "telegraphed in red - read them and roll clear. You cannot facetank.",
        "Clear every monster to open the portal; survive five areas to win.",
    };
    var y = panelY + 18;
    for (lines, 0..) |ln, i| {
        const col = if (i >= 7) rgba(215, 175, 140, 235) else rgba(200, 200, 200, 230);
        centered(ln, y, 18, col);
        y += 26;
    }
}

fn drawDeath(g: *Game) void {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    rl.drawRectangle(0, 0, sw(), sh(), rgba(20, 0, 0, 140));
    const r = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.05;
    rl.drawCircleGradient(cx, cy, r, rgba(0, 0, 0, 0), rgba(130, 0, 0, 210));
    emberField(g.elapsed, 14, rgba(200, 40, 30, 160), true);
    glowCentered("YOU HAVE DIED", cy - 80, 70, rgba(225, 45, 40, 255), rgba(70, 5, 5, 130));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "You reached {s} at level {d} with {d} kills.", .{ g.w.Name, g.p.Level, g.kills }) catch "";
    centered(s, cy + 10, 22, rgba(230, 210, 200, 255));
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    centered("Press R to start a new game", cy + 60, 26, withAlpha(rgba(255, 230, 160, 255), pulse));
}

fn drawVictory(g: *Game) void {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 170));
    const r = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.05;
    rl.drawCircleGradient(cx, cy, r, rgba(0, 0, 0, 0), rgba(90, 60, 0, 160));
    emberField(g.elapsed, 26, rgba(255, 215, 90, 200), false);
    glowCentered("VICTORY!", cy - 90, 80, rgba(255, 215, 80, 255), rgba(120, 80, 10, 130));
    centered("You have cleared the catacombs and triumphed over the darkness.", cy + 10, 22, rgba(230, 220, 200, 255));
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "Final level {d}  -  {d} gold  -  {d} kills", .{ g.p.Level, g.p.Gold, g.kills }) catch "";
    centered(s, cy + 44, 22, rgba(255, 235, 170, 255));
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    centered("Press ENTER to play again", cy + 96, 26, withAlpha(rgba(255, 230, 160, 255), pulse));
}
