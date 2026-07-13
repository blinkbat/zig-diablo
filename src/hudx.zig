const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const gamemod = @import("game.zig");
const playermod = @import("player.zig");
const monster = @import("monster.zig");
const stats = @import("stats.zig");
const theme = @import("theme.zig");

const Game = gamemod.Game;
const Player = playermod.Player;
const rgba = mathx.rgba;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;
const lerpColor = mathx.lerpColor;
const sinf = mathx.sinf;
const v3 = mathx.v3;

// HUD + world overlays + scene screens. 2D only — drawn after endMode3D, so it
// never touches the torch lighting.

// Height (px) of the bottom HUD band (orbs, belt, XP bar). Single source of truth;
// game.zig reads it to ignore world clicks that land on the HUD.
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

// Center-to-corner distance: radius a full-screen radial wash needs. Shared by the
// vignette and every scene-screen gradient.
fn screenDiag() f32 {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    return @sqrt(fi(cx * cx + cy * cy));
}

// Full-screen radial wash: transparent at center, `edge` at the corners. `scale`
// nudges the falloff past the corner so the tint doesn't band. Vignette + scene screens.
fn radialWash(edge: rl.Color, scale: f32) void {
    rl.drawCircleGradient(@divTrunc(sw(), 2), @divTrunc(sh(), 2), screenDiag() * scale, rgba(0, 0, 0, 0), edge);
}

// ---- UI font ----
// IM Fell English (assets/, OFL license alongside) — antique book type for all UI
// text. TWO rasterizations so neither size extreme goes mushy: a display cut for
// titles/banners (>= 40 px) and a text cut for HUD chrome. Falls back to raylib's
// default if the asset is missing (path is CWD-relative — run from repo root).
var fontsLoaded = false;
var haveFont = false;
var fontDisplay: rl.Font = undefined;
var fontText: rl.Font = undefined;

const FONT_PATH = "assets/IMFellEnglish-Regular.ttf";

fn ensureFonts() void {
    if (fontsLoaded) return;
    fontsLoaded = true;
    // Atlas sizes leave downscale-only headroom for every draw size (after the 1.18
    // x-height factor): upscaling a glyph atlas blurs; mild bilinear downscales stay crisp.
    if (rl.loadFontEx(FONT_PATH, 120, null)) |big| {
        fontDisplay = big;
        rl.setTextureFilter(fontDisplay.texture, .bilinear);
        if (rl.loadFontEx(FONT_PATH, 40, null)) |small| {
            fontText = small;
            rl.setTextureFilter(fontText.texture, .bilinear);
            haveFont = true;
        } else |_| {
            rl.unloadFont(fontDisplay);
        }
    } else |_| {}
}

// Free font atlases while the GL context is still live (called from Game.deinit).
fn unloadFonts() void {
    if (haveFont) {
        rl.unloadFont(fontDisplay);
        rl.unloadFont(fontText);
    }
    haveFont = false;
}

fn uiFont(size: i32) rl.Font {
    // Select on the effective render size (after 1.18x), not the requested one:
    // sizes 35-39 render above the 40 px text atlas and must use the display atlas.
    return if (fsize(size) > 40) fontDisplay else fontText;
}

// IM Fell's small x-height reads ~20% under the point size; 1.18x restores presence.
// textW uses the SAME factor so layouts stay glyph-accurate. Rounded to whole pixels:
// fractional render sizes resample glyphs into blur.
fn fsize(size: i32) f32 {
    return @round(fi(size) * 1.18);
}

// Width of s at the given size in the UI font. ALL layout must measure through this
// (never rl.measureText) or centering drifts. (pub: editor overlay reuses it.)
pub fn textW(s: [:0]const u8, size: i32) i32 {
    if (!haveFont) return rl.measureText(s, size);
    return @intFromFloat(rl.measureTextEx(uiFont(size), s, fsize(size), 0).x);
}

// Bare UI-font string draw (no shadow) — the primitive under text().
fn drawStr(s: [:0]const u8, x: i32, y: i32, size: i32, col: rl.Color) void {
    if (!haveFont) {
        rl.drawText(s, x, y, size, col);
        return;
    }
    rl.drawTextEx(uiFont(size), s, .{ .x = fi(x), .y = fi(y) }, fsize(size), 0, col);
}

// Text with a drop shadow for legibility over the 3D scene (1 px under 22, else 2).
pub fn text(s: [:0]const u8, x: i32, y: i32, size: i32, col: rl.Color) void {
    const off: i32 = if (size < 22) 1 else 2;
    // Shadow tracks the face alpha so a fading toast doesn't leave a black ghost.
    drawStr(s, x + off, y + off, size, rgba(0, 0, 0, @intCast(@as(u16, 200) * col.a / 255)));
    drawStr(s, x, y, size, col);
}
fn centered(s: [:0]const u8, cy: i32, size: i32, col: rl.Color) void {
    const w = textW(s, size);
    text(s, @divTrunc(sw(), 2) - @divTrunc(w, 2), cy, size, col);
}

// Big display text with a warm halo: redrawn at four diagonals in a low-alpha ember
// tone, under a hard shadow, under the face.
fn glowCentered(s: [:0]const u8, cy: i32, size: i32, col: rl.Color, halo: rl.Color) void {
    const w = textW(s, size);
    const x = @divTrunc(sw(), 2) - @divTrunc(w, 2);
    for ([_][2]i32{ .{ -3, -3 }, .{ 3, -3 }, .{ -3, 3 }, .{ 3, 3 } }) |off| {
        drawStr(s, x + off[0], cy + off[1], size, halo);
    }
    drawStr(s, x + 3, cy + 4, size, rgba(0, 0, 0, 220));
    drawStr(s, x, cy, size, col);
}

// A soft rounded backing pill behind free-floating text.
pub fn pill(x: i32, y: i32, w: i32, h: i32, col: rl.Color) void {
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y), .width = fi(w), .height = fi(h) }, 0.9, 8, col);
}

// "Measured bar" chrome shared by the enemy plate and XP channel: ink backing under
// the bar, tick dividers + brass frame over it. Caller draws its fill between them.
fn barBacking(x: i32, y: i32, w: i32, h: i32) void {
    rl.drawRectangle(x - 2, y - 2, w + 4, h + 4, withAlpha(theme.ink, 235));
}
fn barTicksFrame(x: i32, y: i32, w: i32, h: i32, ticks: i32, frameAlpha: u8) void {
    var q: i32 = 1;
    while (q < ticks) : (q += 1) {
        rl.drawRectangle(x + @divTrunc(w * q, ticks), y, 1, h, withAlpha(theme.ink, 170));
    }
    rl.drawRectangleLines(x - 2, y - 2, w + 4, h + 4, withAlpha(theme.trimColor, frameAlpha));
}

// Top-level dispatcher: called once per frame after the 3D pass.
pub fn draw(g: *Game) void {
    ensureFonts();
    switch (g.scene) {
        .menu => {
            vignette();
            drawMenu(g);
        },
        .playing => {
            vignette();
            drawHUD(g);
            if (g.sheetOpen) drawStatSheet(g);
            if (g.paused) drawPauseOverlay();
        },
        .dead => {
            vignette();
            drawHUD(g);
            drawDeath(g);
        },
        .victory => {
            vignette();
            drawVictory(g);
        },
        .editor => {}, // editor draws its own overlay (editor.drawOverlay)
    }
}

// Foe owning the top-center plate: the SELECTED target (always-on nearest / sticky pick)
// owns it, so the HUD always names who you'd hit; an aggro'd boss in vision is the
// fallback so a boss fight keeps its bar up even between selections.
fn pickEnemyPlate(g: *Game) ?*const monster.Monster {
    if (g.monsterByID(g.p.targetMonster)) |m| {
        if (g.targetable(m)) return m;
    }
    for (g.liveMonsters()) |*m| {
        if (m.boss and m.alive() and m.aggro and g.inVision(m.Pos)) return m;
    }
    return null;
}

// Top-center enemy plate (PoE/D2 style): foe's name over one wide thin bar — never
// floating bars over heads.
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
    // Heavy-stun meter: a thin channel under the HP bar, shown for every kind that can
    // be heavy-stunned — ALWAYS, even at empty, so the player can read stun progress.
    const showStun = m.heavyStunMax > 0;
    const sbh: i32 = if (boss) 6 else 4;
    const stunPad: i32 = if (showStun) sbh + 3 else 0;
    // Soft backing behind name + bar(s) so they read over any scene.
    pill(bx - 18, 8, bw + 36, by - 8 + bh + 10 + stunPad, withAlpha(theme.ink, 165));
    var nbuf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&nbuf, "{s}", .{m.name.slice()}) catch "";
    centered(name, 14, size, if (boss) rgba(255, 185, 205, 255) else rgba(240, 225, 205, 255));
    barBacking(bx, by, bw, bh);
    const fillCol = if (boss) rgba(225, 45, 105, 255) else rgba(200, 48, 40, 255);
    const frac = clampF(m.HP / m.MaxHP, 0, 1);
    const fw: i32 = @intFromFloat(fi(bw) * frac);
    if (fw > 0) {
        rl.drawRectangleGradientH(bx, by, fw, bh, lerpColor(fillCol, rl.Color.black, 0.3), fillCol);
        rl.drawRectangle(bx, by, fw, 2, withAlpha(lerpColor(fillCol, rl.Color.white, 0.5), 210));
    }
    // Quarter ticks + thin brass frame: the PoE "measured bar" signature.
    barTicksFrame(bx, by, bw, bh, 4, 140);

    // Fills amber as stun damage accumulates; flashes bright white while locked down.
    if (showStun) {
        const sy = by + bh + 3;
        barBacking(bx, sy, bw, sbh);
        if (m.stunned()) {
            // Pulsing white fill for the locked-down window.
            const pulse = 0.6 + 0.4 * sinf(g.elapsed * 12);
            rl.drawRectangle(bx, sy, bw, sbh, withAlpha(rgba(255, 250, 220, 255), mathx.u8f(clampF(pulse * 255, 0, 255))));
        } else {
            const sfrac = clampF(m.stunFill, 0, 1);
            const sfw: i32 = @intFromFloat(fi(bw) * sfrac);
            const stunCol = rgba(240, 205, 90, 255);
            if (sfw > 0) rl.drawRectangleGradientH(bx, sy, sfw, sbh, lerpColor(stunCol, rl.Color.black, 0.35), stunCol);
        }
        rl.drawRectangleLines(bx - 2, sy - 2, bw + 4, sbh + 4, withAlpha(theme.trimColor, 110));
    }
}

// No floating combat text (owner decree): hit sparks, gore, orbs, and the enemy
// plate carry all combat feedback.

// ---- Character stat sheet ----
// Opened with C / Select (freezes the world). Left column: six attributes then three
// skills, both allocatable via the cursor (d-pad/arrows + confirm). Right column:
// derived stats (read-only). SHEET_DR_REF is a fixed reference hit size for the armor
// %DR readout — PoE2 armor is hit-size dependent, so a flat % would lie.
const SHEET_DR_REF: f32 = 40; // "% vs a 40-damage physical hit"

const sheetGold = rgba(224, 190, 120, 255);
const sheetInk = rgba(232, 222, 202, 255);

// Allocatable row: label left, value right, green "+" when a point can be spent,
// warm highlight box when it's the cursor.
fn sheetAllocRow(x: i32, y: i32, w: i32, label: [:0]const u8, val: [:0]const u8, selected: bool, canAlloc: bool) void {
    if (selected) {
        rl.drawRectangle(x - 8, y - 4, w + 16, 25, withAlpha(rgba(180, 140, 70, 255), 70));
        rl.drawRectangleLines(x - 8, y - 4, w + 16, 25, withAlpha(theme.trimColor, 150));
    }
    text(label, x, y, 18, sheetInk);
    const showPlus = selected and canAlloc;
    const vw = textW(val, 18);
    const plusGap: i32 = if (showPlus) 24 else 0;
    text(val, x + w - vw - plusGap, y, 18, rgba(245, 235, 210, 255));
    if (showPlus) text("+", x + w - 16, y - 1, 20, rgba(150, 230, 150, 255));
}

// One read-only derived-stat row.
fn sheetStatRow(x: i32, y: i32, w: i32, label: [:0]const u8, val: [:0]const u8) void {
    text(label, x, y, 18, rgba(196, 186, 168, 255));
    const vw = textW(val, 18);
    text(val, x + w - vw, y, 18, sheetInk);
}

fn drawStatSheet(g: *Game) void {
    const p = &g.p;
    const W = sw();
    const H = sh();
    // Dim the frozen world behind the panel.
    rl.drawRectangle(0, 0, W, H, withAlpha(rgba(6, 4, 8, 255), 200));

    const pw: i32 = 760;
    const ph: i32 = 540;
    const px = @divTrunc(W - pw, 2);
    const py = @divTrunc(H - ph, 2);
    pill(px, py, pw, ph, withAlpha(theme.ink, 244));
    rl.drawRectangleLines(px, py, pw, ph, withAlpha(theme.trimColor, 170));

    centered("Character", py + 20, 34, rgba(240, 225, 205, 255));
    var hbuf: [128]u8 = undefined;
    const head = std.fmt.bufPrintZ(&hbuf, "Level {d}    Attribute Points: {d}    Skill Points: {d}", .{ p.Level, p.attrPoints, p.skillPoints }) catch "";
    centered(head, py + 62, 18, rgba(214, 199, 178, 255));

    const colY = py + 104;
    const leftX = px + 44;
    const colW = @divTrunc(pw, 2) - 72;
    const rightX = px + @divTrunc(pw, 2) + 28;
    const rowH: i32 = 30;

    // ── Left: attributes, then skills (allocatable) ──
    text("Attributes", leftX, colY, 22, sheetGold);
    var vbuf: [24]u8 = undefined;
    for (stats.Attribs.order, 0..) |k, i| {
        const y = colY + 32 + @as(i32, @intCast(i)) * rowH;
        const sel = g.sheetSel == @as(i32, @intCast(i));
        const val = std.fmt.bufPrintZ(&vbuf, "{d}", .{p.attribs.get(k)}) catch "";
        sheetAllocRow(leftX, y, colW, stats.Attribs.label(k), val, sel, p.attrPoints > 0);
    }

    const skHdrY = colY + 32 + 6 * rowH + 14;
    text("Skills", leftX, skHdrY, 22, sheetGold);
    // Iterate gamemod.sheetSkills (the sheet's skill order); label + rank come from
    // the Skill enum / Player, so there is no parallel label/rank list to drift.
    for (gamemod.sheetSkills, 0..) |sk, i| {
        const y = skHdrY + 32 + @as(i32, @intCast(i)) * rowH;
        const sel = g.sheetSel == gamemod.SHEET_ATTR_COUNT + @as(i32, @intCast(i));
        var rbuf: [24]u8 = undefined;
        const val = std.fmt.bufPrintZ(&rbuf, "Rank {d}", .{p.skillRank(sk)}) catch "";
        sheetAllocRow(leftX, y, colW, sk.label(), val, sel, p.skillPoints > 0);
    }

    // Effect note for the selected attribute, in the left column's whitespace below
    // Skills (skill rows have no note).
    if (g.sheetSel < gamemod.SHEET_ATTR_COUNT) {
        const k = stats.Attribs.order[@intCast(g.sheetSel)];
        const noteY = skHdrY + 32 + @as(i32, @intCast(gamemod.sheetSkills.len)) * rowH + 14;
        text(stats.Attribs.note(k), leftX, noteY, 16, rgba(206, 194, 172, 235));
    }

    // ── Right: derived stats (read-only totals) ──
    text("Defense", rightX, colY, 22, sheetGold);
    var b: [40]u8 = undefined;
    var yy = colY + 32;
    sheetStatRow(rightX, yy, colW, "Life", std.fmt.bufPrintZ(&b, "{d:.0}", .{p.MaxHP}) catch "");
    yy += rowH;
    var b2: [40]u8 = undefined;
    sheetStatRow(rightX, yy, colW, "Mana", std.fmt.bufPrintZ(&b2, "{d:.0}", .{p.MaxMana}) catch "");
    yy += rowH;
    var b3: [48]u8 = undefined;
    const drPct = stats.physReduction(p.def.armor, SHEET_DR_REF) * 100;
    sheetStatRow(rightX, yy, colW, "Armor", std.fmt.bufPrintZ(&b3, "{d:.0}  ({d:.0}% vs {d:.0})", .{ p.def.armor, drPct, SHEET_DR_REF }) catch "");
    yy += rowH;
    // Four resists, driven by the one canonical elemental list + its label.
    for (stats.DamageType.elementals) |rk| {
        var lb: [24]u8 = undefined;
        var pb: [16]u8 = undefined;
        const ll = std.fmt.bufPrintZ(&lb, "{s} Res", .{rk.label()}) catch rk.label();
        sheetStatRow(rightX, yy, colW, ll, std.fmt.bufPrintZ(&pb, "{d:.0}%", .{p.def.resFor(rk) * 100}) catch "");
        yy += rowH;
    }

    yy += 12;
    text("Offense", rightX, yy, 22, sheetGold);
    yy += 32;
    var o1: [40]u8 = undefined;
    sheetStatRow(rightX, yy, colW, "Melee", std.fmt.bufPrintZ(&o1, "{d:.0}-{d:.0}", .{ p.MinDmg, p.MaxDmg }) catch "");
    yy += rowH;
    var o2: [40]u8 = undefined;
    sheetStatRow(rightX, yy, colW, "Spell", std.fmt.bufPrintZ(&o2, "{d:.0}", .{p.spellDmg}) catch "");
    yy += rowH;
    var o3: [40]u8 = undefined;
    sheetStatRow(rightX, yy, colW, "Crit", std.fmt.bufPrintZ(&o3, "{d:.0}%", .{p.derived.critChance * 100}) catch "");
    yy += rowH;
    var o4: [40]u8 = undefined;
    sheetStatRow(rightX, yy, colW, "Cooldown Red.", std.fmt.bufPrintZ(&o4, "{d:.0}%", .{p.derived.cdrFrac * 100}) catch "");

    // Footer hint (controller + keyboard).
    centered("[Up/Down] select   [Confirm/+] spend   [Select/C] close", py + ph - 32, 15, rgba(176, 166, 150, 220));
}

// ---- 3D liquid orbs ----
// Each orb is a real lit 3D scene rendered offscreen once per frame: a sphere mesh
// with an N-dot-L liquid clipped at its fill plane IN THE SHADER, an elliptical
// meniscus disc under a perspective camera, rising bubbles, and a fresnel glass
// shell — composited into the iron socket. One shared RT + mesh + shader for both.

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

// Called from Game.deinit so GPU assets (orb RT/shader/mesh + font atlases) don't
// outlive the GL context. The orb material only wraps orbShader (freed here); its
// tiny default-map array is left to the OS to avoid a double-free (same as SceneMesh).
pub fn unloadOrbRT() void {
    if (orbRT) |rt| {
        rl.unloadRenderTexture(rt);
        rl.unloadShader(orbShader);
        rl.unloadMesh(orbMesh);
    }
    orbRT = null;
    unloadFonts();
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
        .position = v3(0, 0.9, 4.3), // must match hardcoded V in orbFS
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

    // Drained interior: near-black liquid to the brim, slightly shrunken so the
    // real liquid shell wins the depth test over it.
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

        // Surface + bubbles read through the liquid front: painter's order.
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

// Liquid glass globe in an iron-and-brass socket (renderOrbScene composited here).
// Pulses an alarm glow when low.
fn drawOrb(cx: i32, cy: i32, radius: i32, frac_in: f32, full: rl.Color, empty: rl.Color, t: f32) void {
    const frac = clampF(frac_in, 0, 1);
    const rf = fi(radius);

    // Low-resource alarm: soft pulsing halo outside the socket.
    if (frac < 0.28) {
        const pa = mathx.u8f(50 + 45 * sinf(t * 6));
        rl.drawCircle(cx, cy, rf + 9, withAlpha(lerpColor(full, rl.Color.white, 0.15), pa));
    }

    rl.drawCircle(cx, cy, rf + 5, withAlpha(theme.ink, 235));

    if (ensureOrbAssets()) |rt| {
        renderOrbScene(rt, frac, full, empty, t, fi(cx) * 0.017);
        // Scale so the sphere's projected radius (~123 px of the 256 RT under the
        // 26-deg camera) lands on the socket rim.
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
        // RT fallback: flat fill so the HUD still reports the resource.
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

    // Damage flash: red pain in the screen RIM only — a border vignette that leaves
    // the scene lighting alone. A center wash over the fog's black read as the torch
    // radius glitching red, not pain; the center must stay untouched.
    if (g.damageFlash > 0) {
        const k = clampF(g.damageFlash / gamemod.DAMAGE_FLASH_DUR, 0, 1);
        const a = mathx.u8f(150 * k);
        const band: i32 = @intFromFloat(@as(f32, @floatFromInt(@min(W, H))) * 0.16);
        const red = rgba(185, 12, 10, a);
        const clear = rgba(185, 12, 10, 0);
        rl.drawRectangleGradientV(0, 0, W, band, red, clear);
        rl.drawRectangleGradientV(0, H - band, W, band, clear, red);
        rl.drawRectangleGradientH(0, 0, band, H, red, clear);
        rl.drawRectangleGradientH(W - band, 0, band, H, clear, red);
    }

    // One fixed-width command cluster centered on the bottom edge: two orbs bracket
    // a bound panel (flasks, dodge, gold, XP), keeping combat vitals in one gaze.
    const hudW: i32 = @min(W - 24, 840);
    const hudX = @divTrunc(W - hudW, 2);
    const orbR: i32 = 56;
    const orbY = H - orbR - 22;
    const healthCX = hudX + orbR + 4;
    const manaCX = hudX + hudW - orbR - 4;

    drawOrb(healthCX, orbY, orbR, p.HP / p.MaxHP, theme.healthColor, theme.healthSocket, t);
    var b1: [64]u8 = undefined;
    const hp = std.fmt.bufPrintZ(&b1, "{d}/{d}", .{ @as(i32, @intFromFloat(p.HP)), @as(i32, @intFromFloat(p.MaxHP)) }) catch "";
    text(hp, healthCX - @divTrunc(textW(hp, 16), 2), orbY - 8, 16, rl.Color.white);

    drawOrb(manaCX, orbY, orbR, p.Mana / p.MaxMana, theme.manaColor, theme.manaSocket, t);
    var b2: [64]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&b2, "{d}/{d}", .{ @as(i32, @intFromFloat(p.Mana)), @as(i32, @intFromFloat(p.MaxMana)) }) catch "";
    text(mp, manaCX - @divTrunc(textW(mp, 16), 2), orbY - 8, 16, rl.Color.white);

    // XP: burnished-gold channel orb to orb, notched at each tenth, with a slow
    // light sweep over the fill.
    const xpX = healthCX + orbR + 18;
    const xpW = manaCX - orbR - 18 - xpX;
    const xpY = H - 24;
    const frac = if (p.XPNext > 0) @as(f32, @floatFromInt(p.XP)) / @as(f32, @floatFromInt(p.XPNext)) else 0;
    barBacking(xpX, xpY, xpW, 8);
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
    barTicksFrame(xpX, xpY, xpW, 8, 10, 110);

    var b3: [32]u8 = undefined;
    const lvl = std.fmt.bufPrintZ(&b3, "Level {d}", .{p.Level}) catch "";
    text(lvl, @divTrunc(W, 2) - @divTrunc(textW(lvl, 14), 2), H - 42, 14, rgba(235, 210, 150, 220));

    drawBelt(p, @divTrunc(W, 2), H - 58);

    // Dodge readiness: arc sweeps around as the roll recharges, then settles to a
    // steady bright ring when the escape is available.
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

    // Transient status toast (top-center pill, under the enemy plate zone).
    if (g.toast.active()) {
        const a = mathx.u8f(clampF(g.toast.time / gamemod.TOAST_DUR * 255, 0, 255));
        const toastW = textW(g.toast.text(), 22);
        pill(@divTrunc(W, 2) - @divTrunc(toastW, 2) - 16, 78, toastW + 32, 36, withAlpha(theme.ink, mathx.u8f(fi(a) * 0.55)));
        centered(g.toast.text(), 84, 22, withAlpha(rgba(255, 245, 210, 255), a));
    }

    // Area-name banner: glowing title flanked by fading gold rules.
    if (g.banner.active()) {
        const a = clampF(g.banner.time, 0, 1);
        const a8 = mathx.u8f(a * 255);
        const by = @divTrunc(H, 3);
        const bw = textW(g.banner.text(), 56);
        const ruleY = by + 30;
        const ruleW: i32 = 150;
        const gapL = @divTrunc(W, 2) - @divTrunc(bw, 2) - 24;
        const gapR = @divTrunc(W, 2) + @divTrunc(bw, 2) + 24;
        rl.drawRectangleGradientH(gapL - ruleW, ruleY, ruleW, 2, withAlpha(theme.goldColor, 0), withAlpha(theme.goldColor, a8));
        rl.drawRectangleGradientH(gapR, ruleY, ruleW, 2, withAlpha(theme.goldColor, a8), withAlpha(theme.goldColor, 0));
        glowCentered(g.banner.text(), by, 56, withAlpha(rgba(255, 225, 160, 255), a8), withAlpha(rgba(160, 70, 20, 255), @intFromFloat(fi(a8) * 0.35)));
    }
}

// Corked flask icon (bulb + neck + shine), used by the belt slots.
fn flaskIcon(x: i32, y: i32, col: rl.Color) void {
    rl.drawRectangle(x + 4, y + 2, 6, 5, rgba(24, 20, 16, 255)); // neck
    rl.drawRectangle(x + 3, y, 8, 3, theme.corkColor); // cork
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y + 6), .width = 14, .height = 13 }, 0.7, 6, lerpColor(col, rl.Color.black, 0.25));
    rl.drawRectangleRounded(.{ .x = fi(x + 2), .y = fi(y + 8), .width = 10, .height = 9 }, 0.7, 6, col);
    rl.drawRectangle(x + 3, y + 9, 2, 5, withAlpha(rl.Color.white, 90)); // glass shine
}

// Framed belt slot: dark well, brass liner, flask, count badge, and its hotkey on a
// chip above. Greys out when the belt runs dry.
fn flaskSlot(x: i32, y: i32, col: rl.Color, count: i32, key: [:0]const u8) void {
    const have = count > 0;
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y), .width = 30, .height = 36 }, 0.3, 6, rgba(12, 9, 8, 215));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x), .y = fi(y), .width = 30, .height = 36 }, 0.3, 6, 1, withAlpha(theme.trimColor, if (have) 170 else 70));
    flaskIcon(x + 8, y + 5, if (have) col else lerpColor(col, rgba(40, 40, 44, 255), 0.75));
    // Count badge, bottom-right.
    var cb: [8]u8 = undefined;
    const ct = std.fmt.bufPrintZ(&cb, "{d}", .{count}) catch "";
    text(ct, x + 28 - textW(ct, 14), y + 22, 14, if (have) rl.Color.white else rgba(140, 130, 125, 200));
    // Hotkey chip.
    rl.drawRectangleRounded(.{ .x = fi(x + 8), .y = fi(y - 16), .width = 14, .height = 14 }, 0.3, 4, rgba(14, 11, 9, 220));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x + 8), .y = fi(y - 16), .width = 14, .height = 14 }, 0.3, 4, 1, withAlpha(theme.trimColor, 140));
    drawStr(key, x + 12, y - 14, 10, rgba(215, 195, 160, 235));
}

// Centered belt cluster: two flask slots flanking the gold readout.
fn drawBelt(p: *const Player, cx: i32, y: i32) void {
    var b3: [24]u8 = undefined;
    const goldTxt = std.fmt.bufPrintZ(&b3, "{d} g", .{p.Gold}) catch "";
    flaskSlot(cx - 76, y - 18, theme.healthColor, p.HealthPots, "1");
    flaskSlot(cx + 46, y - 18, theme.manaColor, p.ManaPots, "2");
    text(goldTxt, cx - @divTrunc(textW(goldTxt, 16), 2), y, 16, theme.goldColor);
}

// Top-right iron plaque: enemy count behind a skull pip, with the FPS / frame-time /
// object readout small and grey beneath it.
fn drawTopRight(g: *Game) void {
    const W = sw();
    var b1: [32]u8 = undefined;
    const en = std.fmt.bufPrintZ(&b1, "{d}", .{g.remainingMonsters()}) catch "";
    var b2: [64]u8 = undefined;
    const perf = std.fmt.bufPrintZ(&b2, "FPS {d}  {d:.1} ms  {d} obj", .{ rl.getFPS(), rl.getFrameTime() * 1000, g.objectCount() }) catch "";
    const w = @max(textW(en, 22) + 46, textW(perf, 12) + 24);
    const x = W - w - 10;
    pill(x, 8, w, 50, withAlpha(theme.ink, 175));
    rl.drawRectangleRoundedLinesEx(.{ .x = fi(x), .y = 8, .width = fi(w), .height = 50 }, 0.9, 8, 1, withAlpha(theme.trimColor, 110));
    // Skull pip: cranium, jaw, hollow sockets.
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
    radialWash(rgba(0, 0, 0, 150), 1.02);
}

// Stateless drifting screen embers: each mote's path is a pure function of time and
// index, so scene screens get living air with zero bookkeeping. `upward` embers rise
// (menu, death); otherwise they fall like gold rain (victory).
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

// Start menu: title + a column of selectable items. Keyboard owns `menuSel` from the
// run loop; here mouse hover selects and click activates (gamemod.menuActivate is the
// single activation path for both).
fn drawMenu(g: *Game) void {
    const t = g.elapsed;
    const W = sw();
    const H = sh();
    rl.drawRectangle(0, 0, W, H, rgba(4, 3, 6, 175));
    emberField(t, 22, rgba(255, 140, 50, 200), true);

    // Smoldering backglow breathes behind the title. (Size 76 keeps the render size
    // inside the 120 px display atlas — never upscale the title.)
    rl.drawCircleGradient(@divTrunc(W, 2), @divTrunc(H, 2) - 125, 320, rgba(120, 16, 8, mathx.u8f(60 + 25 * sinf(t * 1.8))), rgba(120, 16, 8, 0));
    glowCentered("ZIG DIABLO", @divTrunc(H, 2) - 180, 76, rgba(210, 45, 40, 255), withAlpha(rgba(90, 8, 8, 255), mathx.u8f(95 + 35 * sinf(t * 1.8))));
    const ruleW: i32 = 340;
    rl.drawRectangleGradientH(@divTrunc(W, 2) - ruleW, @divTrunc(H, 2) - 86, ruleW, 2, withAlpha(theme.goldColor, 0), theme.goldColor);
    rl.drawRectangleGradientH(@divTrunc(W, 2), @divTrunc(H, 2) - 86, ruleW, 2, theme.goldColor, withAlpha(theme.goldColor, 0));

    var dispBuf: [48]u8 = undefined;
    const dispLabel: [:0]const u8 = std.fmt.bufPrintZ(&dispBuf, "Display: {s}", .{switch (g.displayMode) {
        .windowed => @as([]const u8, "Windowed"),
        .borderless => "Fullscreen Windowed",
        .fullscreen => "Fullscreen",
    }}) catch "Display";

    // Debug Log row (under Options) shows its live state, like the display cycler.
    var dbgBuf: [32]u8 = undefined;
    const dbgLabel: [:0]const u8 = std.fmt.bufPrintZ(&dbgBuf, "Debug Log: {s}", .{if (g.debugLog) @as([]const u8, "On") else "Off"}) catch "Debug Log";
    // Top row reads "Continue" while a run is paused behind the menu, else "Adventure".
    var rootItems = gamemod.menuRootItems;
    rootItems[@intFromEnum(gamemod.RootItem.adventure)] = if (g.canResume) "Continue" else "Adventure";
    // 1:1 with gamemod.OptionsItem (display, debug, back) — asserted below so labels
    // and dispatch can't drift.
    const optItems = [_][:0]const u8{ dispLabel, dbgLabel, "Back" };
    comptime std.debug.assert(optItems.len == @typeInfo(gamemod.OptionsItem).@"enum".fields.len);
    const items: []const [:0]const u8 = if (g.menuMode == .root) &rootItems else &optItems;

    const mouse = rl.getMousePosition();
    var y = @divTrunc(H, 2) - 20;
    for (items, 0..) |label, i| {
        const idx: i32 = @intCast(i);
        const selected = g.menuSel == idx;
        const size: i32 = if (selected) 36 else 30;
        const w = textW(label, size);
        const r = rl.Rectangle{ .x = fi(@divTrunc(W, 2) - @divTrunc(w, 2) - 20), .y = fi(y - 6), .width = fi(w + 40), .height = 46 };
        if (rl.checkCollisionPointRec(mouse, r)) {
            g.menuSel = idx;
            if (rl.isMouseButtonPressed(.left)) gamemod.menuActivate(g, idx);
        }
        if (selected) {
            // Gold daggers flank the chosen line, breathing.
            const flare = mathx.u8f(180 + 60 * sinf(t * 3));
            const gap = @divTrunc(w, 2) + 34;
            text("-", @divTrunc(W, 2) - gap - 14, y + 6, 28, withAlpha(theme.goldColor, flare));
            text("-", @divTrunc(W, 2) + gap, y + 6, 28, withAlpha(theme.goldColor, flare));
            centered(label, y, size, rgba(255, 228, 160, 255));
        } else {
            centered(label, y + 3, size, rgba(205, 188, 165, 215));
        }
        y += 56;
    }

    if (g.menuMode == .options) {
        centered("Alt+Enter toggles fullscreen windowed anywhere", y + 14, 15, rgba(170, 158, 140, 190));
    }
}

fn drawDeath(g: *Game) void {
    const cy = @divTrunc(sh(), 2);
    rl.drawRectangle(0, 0, sw(), sh(), rgba(20, 0, 0, 140));
    radialWash(rgba(130, 0, 0, 210), 1.05);
    emberField(g.elapsed, 14, rgba(200, 40, 30, 160), true);
    glowCentered("YOU HAVE DIED", cy - 80, 70, rgba(225, 45, 40, 255), rgba(70, 5, 5, 130));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "You reached {s} at level {d} with {d} kills.", .{ g.map.name.slice(), g.p.Level, g.kills }) catch "";
    centered(s, cy + 10, 22, rgba(230, 210, 200, 255));
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    centered("Press R to start a new game", cy + 60, 26, withAlpha(rgba(255, 230, 160, 255), pulse));
}

fn drawVictory(g: *Game) void {
    const cy = @divTrunc(sh(), 2);
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 170));
    radialWash(rgba(90, 60, 0, 160), 1.05);
    emberField(g.elapsed, 26, rgba(255, 215, 90, 200), false);
    glowCentered("VICTORY!", cy - 90, 80, theme.goldColor, rgba(120, 80, 10, 130));
    centered("You have cleared the catacombs and triumphed over the darkness.", cy + 10, 22, rgba(230, 220, 200, 255));
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "Final level {d}  -  {d} gold  -  {d} kills", .{ g.p.Level, g.p.Gold, g.kills }) catch "";
    centered(s, cy + 44, 22, rgba(255, 235, 170, 255));
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    centered("Press ENTER to play again", cy + 96, 26, withAlpha(rgba(255, 230, 160, 255), pulse));
}
