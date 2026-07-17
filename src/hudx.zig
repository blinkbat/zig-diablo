const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const gamemod = @import("game.zig");
const playermod = @import("player.zig");
const input = @import("input.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
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
    // Engraved metal-leaf bands riding the letterforms (alpha-preserving so
    // fading banners keep their fade).
    const hh: i32 = @intFromFloat(fsize(size));
    rl.beginScissorMode(x - 2, cy, w + 4, @divTrunc(hh * 45, 100));
    drawStr(s, x, cy, size, withAlpha(lerpColor(col, rgba(255, 246, 218, 255), 0.30), col.a));
    rl.endScissorMode();
    rl.beginScissorMode(x - 2, cy + @divTrunc(hh * 72, 100), w + 4, hh);
    drawStr(s, x, cy, size, withAlpha(lerpColor(col, rl.Color.black, 0.38), col.a));
    rl.endScissorMode();
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
    forgedRect(x - 2, y - 2, w + 4, h + 4, withAlpha(theme.trimColor, frameAlpha));
}

// `frac` of the width as a dark→`col` gradient with an optional bright top sheen
// (sheenA=0 omits it). Shared by the enemy HP and heavy-stun channels so the fill's
// guard + gradient live once. (XP keeps its own brass palette, not a color-lerp.)
fn barFill(x: i32, y: i32, w: i32, h: i32, frac: f32, col: rl.Color, darken: f32, sheenA: u8) void {
    const fw: i32 = @intFromFloat(fi(w) * clampF(frac, 0, 1));
    if (fw <= 0) return;
    rl.drawRectangleGradientH(x, y, fw, h, lerpColor(col, rl.Color.black, darken), col);
    if (sheenA > 0) rl.drawRectangle(x, y, fw, 2, withAlpha(lerpColor(col, rl.Color.white, 0.5), sheenA));
    // Meniscus: a bright hairline rides the fill's leading edge — liquid in glass.
    if (frac < 0.999) rl.drawRectangle(x + fw - 1, y, 2, h, withAlpha(lerpColor(col, rl.Color.white, 0.6), 190));
}

// ---- Antiquarian chrome ----
// BG2/D2 dressing shared HUD-wide: oiled-wood slabs, riveted iron framing, brass
// liners, diamond finials. All raylib vectors — no texture assets to load or lose.

fn rivet(cx: i32, cy: i32, r: f32) void {
    const c = rl.Vector2.init(fi(cx), fi(cy));
    rl.drawCircleV(c, r + 1.5, withAlpha(theme.ink, 220)); // seat shadow
    rl.drawCircleV(c, r, theme.ironLight);
    rl.drawCircleV(.{ .x = fi(cx) - r * 0.30, .y = fi(cy) - r * 0.35 }, r * 0.35, withAlpha(theme.highlightColor, 190)); // catchlight
}

// drawPoly's first vertex sits at 3 o'clock, so 4 sides at rotation 0 is the diamond.
fn diamond(cx: i32, cy: i32, r: f32, col: rl.Color) void {
    rl.drawPoly(.{ .x = fi(cx), .y = fi(cy) }, 4, r, 0, col);
}

// Brass finial: iron seat, brass body, bright heart. Caps bar ends and rule terminals.
fn finial(cx: i32, cy: i32, r: f32, a: u8) void {
    diamond(cx, cy, r + 2, withAlpha(theme.ironDark, a));
    diamond(cx, cy, r, withAlpha(theme.trimColor, a));
    diamond(cx, cy, r * 0.45, withAlpha(theme.highlightColor, a));
}

// Matched fading gold rules flanking a centered span, finials on the inner ends —
// the one "ornate underline" the banner and title screens share.
fn ornateRules(cx: i32, y: i32, halfGap: i32, ruleW: i32, a: u8) void {
    rl.drawRectangleGradientH(cx - halfGap - ruleW, y, ruleW, 2, withAlpha(theme.goldColor, 0), withAlpha(theme.goldColor, a));
    rl.drawRectangleGradientH(cx + halfGap, y, ruleW, 2, withAlpha(theme.goldColor, a), withAlpha(theme.goldColor, 0));
    finial(cx - halfGap, y + 1, 4, a);
    finial(cx + halfGap, y + 1, 4, a);
}

// Stateless hash noise in [-1, 1): the "hand" in hand-forged lines and hammered
// plates — a pure function of position, so nothing shimmers frame to frame.
fn wob(a: f32, b: f32) f32 {
    const s = sinf(a * 12.9898 + b * 78.233) * 43758.547;
    return (s - @floor(s)) * 2 - 1;
}

// Candlelit breathing for brass liners: slow alpha sway, phase-keyed by x so
// separate panels don't pulse in lockstep. Set once per frame in draw().
var chromeT: f32 = 0;
fn flickA(base: u8, x: i32) u8 {
    return mathx.u8f(fi(base) * (0.86 + 0.14 * sinf(chromeT * 1.9 + fi(x) * 0.31)));
}

// Hand-forged stroke: short segments wavering off true, so edges read hammered
// at a smithy rather than plotted.
fn forgedH(x: i32, y: i32, w: i32, col: rl.Color) void {
    const fy = fi(y);
    const endX = fi(x + w);
    var ax = fi(x);
    var ay = fy + wob(ax, fy) * 1.1;
    while (ax < endX) {
        const bx = @min(ax + 13, endX);
        const by = fy + wob(bx, fy) * 1.1;
        rl.drawLineEx(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by }, 1.2, col);
        ax = bx;
        ay = by;
    }
}
fn forgedV(x: i32, y: i32, h: i32, col: rl.Color) void {
    const fx = fi(x);
    const endY = fi(y + h);
    var ay = fi(y);
    var ax = fx + wob(fx, ay) * 1.1;
    while (ay < endY) {
        const by = @min(ay + 13, endY);
        const bx = fx + wob(fx, by) * 1.1;
        rl.drawLineEx(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by }, 1.2, col);
        ay = by;
        ax = bx;
    }
}
fn forgedRect(x: i32, y: i32, w: i32, h: i32, col: rl.Color) void {
    forgedH(x, y, w, col);
    forgedH(x, y + h, w, col);
    forgedV(x, y, h, col);
    forgedV(x + w, y, h, col);
}

// Pein dents: the hammered finish scattered over iron bands and plates.
fn hammered(x: i32, y: i32, w: i32, h: i32, n: i32) void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const f = fi(i) + fi(x) * 0.13 + fi(y) * 0.07; // de-sync per site
        const dx = fi(x) + @mod(f * 0.618, 1.0) * fi(w);
        const dy = fi(y) + @mod(f * 0.414, 1.0) * fi(h);
        const r = 1.2 + @mod(f * 0.377, 1.0) * 1.8;
        rl.drawCircleV(.{ .x = dx, .y = dy }, r, withAlpha(rl.Color.black, 30));
        rl.drawCircleV(.{ .x = dx - r * 0.35, .y = dy - r * 0.35 }, r * 0.45, withAlpha(theme.highlightColor, 16));
    }
}

// Quatrefoil boss: four iron petals under brass ones around a bright stud — the
// chapel rosette that keystones the big panels.
fn quatrefoil(cx: i32, cy: i32, r: f32, a: u8) void {
    const dirs = [_][2]f32{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };
    for (dirs) |d| rl.drawCircleV(.{ .x = fi(cx) + d[0] * r * 0.58, .y = fi(cy) + d[1] * r * 0.58 }, r * 0.52, withAlpha(theme.ironDark, a));
    for (dirs) |d| rl.drawCircleV(.{ .x = fi(cx) + d[0] * r * 0.58, .y = fi(cy) + d[1] * r * 0.58 }, r * 0.34, withAlpha(theme.trimColor, a));
    rl.drawCircleV(.{ .x = fi(cx), .y = fi(cy) }, r * 0.40, withAlpha(theme.ironDark, a));
    rl.drawCircleV(.{ .x = fi(cx), .y = fi(cy) }, r * 0.26, withAlpha(theme.highlightColor, a));
}

// Corner scrollwork: nested brass arcs curling into the corner, a diamond on the
// diagonal, dots at the arc tips — quill flourish, not CAD. corner: 0 TL cw.
fn scrollCorner(cx: i32, cy: i32, corner: u2, a: u8) void {
    const sxv: f32 = if (corner == 0 or corner == 3) 1 else -1;
    const syv: f32 = if (corner < 2) 1 else -1;
    const start: f32 = switch (corner) {
        0 => 180,
        1 => 270,
        2 => 0,
        3 => 90,
    };
    const c = rl.Vector2.init(fi(cx) + sxv * 19, fi(cy) + syv * 19);
    rl.drawRing(c, 16, 17.2, start, start + 90, 20, withAlpha(theme.trimColor, a));
    rl.drawRing(c, 10.5, 11.4, start + 8, start + 82, 16, withAlpha(theme.trimColor, mathx.u8f(fi(a) * 0.6)));
    diamond(cx + @as(i32, @intFromFloat(sxv * 8)), cy + @as(i32, @intFromFloat(syv * 8)), 3, withAlpha(theme.trimColor, a));
    for ([_]f32{ start, start + 90 }) |deg| {
        const rr = mathx.radians(deg);
        rl.drawCircleV(.{ .x = c.x + mathx.cosf(rr) * 16.6, .y = c.y + mathx.sinf(rr) * 16.6 }, 2.0, withAlpha(theme.trimColor, a));
    }
}

// Engraved lettering: top-lit metal leaf. Hard shadow, full body, then a bright
// band scissored over the upper face and a deep band under the lower — both
// re-draws of the same string, so the gradient rides the letterforms exactly.
// Heading tier and up only (bands collapse into noise below ~20 px).
fn engraved(s: [:0]const u8, x: i32, y: i32, size: i32, col: rl.Color) void {
    const hh: i32 = @intFromFloat(fsize(size));
    const w = textW(s, size);
    const off: i32 = if (size < 22) 1 else 2;
    drawStr(s, x + off, y + off, size, rgba(0, 0, 0, @intCast(@as(u16, 200) * col.a / 255)));
    drawStr(s, x, y, size, col);
    rl.beginScissorMode(x - 2, y, w + 4, @divTrunc(hh * 45, 100));
    drawStr(s, x, y, size, withAlpha(lerpColor(col, rgba(255, 246, 218, 255), 0.36), col.a));
    rl.endScissorMode();
    rl.beginScissorMode(x - 2, y + @divTrunc(hh * 72, 100), w + 4, hh);
    drawStr(s, x, y, size, withAlpha(lerpColor(col, rl.Color.black, 0.40), col.a));
    rl.endScissorMode();
}
fn engravedCentered(s: [:0]const u8, cy: i32, size: i32, col: rl.Color) void {
    engraved(s, @divTrunc(sw(), 2) - @divTrunc(textW(s, size), 2), cy, size, col);
}

// Hanging strap: a short iron band bolting a top-edge plaque to the screen's
// sill — the top-side mirror of the orb pedestals. Drawn over the plaque frame
// so the rivet reads driven through both.
fn hangStrap(cx: i32, plaqueTop: i32) void {
    rl.drawRectangle(cx - 3, 0, 6, plaqueTop + 7, theme.ironDark);
    rl.drawRectangle(cx - 3, 0, 1, plaqueTop + 7, withAlpha(theme.ironLight, 130));
    rivet(cx, plaqueTop + 3, 2.0);
}

// Gilt fleuron: a diamond heart, teardrop leaves on the four compass points, and
// a bright pip — the small-scale ornament for dividers and ledger notes (the
// quatrefoil stays the large-scale keystone boss).
fn fleuron(cx: i32, cy: i32, r: f32, col: rl.Color) void {
    diamond(cx, cy, r, col);
    const leafR = r * 0.9;
    const off = r + 2;
    const xf = fi(cx);
    const yf = fi(cy);
    const half = leafR * 0.55;
    rl.drawTriangle(.{ .x = xf + off + leafR, .y = yf }, .{ .x = xf + off, .y = yf - half }, .{ .x = xf + off, .y = yf + half }, col);
    rl.drawTriangle(.{ .x = xf - off - leafR, .y = yf }, .{ .x = xf - off, .y = yf + half }, .{ .x = xf - off, .y = yf - half }, col);
    rl.drawTriangle(.{ .x = xf, .y = yf - off - leafR }, .{ .x = xf - half, .y = yf - off }, .{ .x = xf + half, .y = yf - off }, col);
    rl.drawTriangle(.{ .x = xf, .y = yf + off + leafR }, .{ .x = xf + half, .y = yf + off }, .{ .x = xf - half, .y = yf + off }, col);
    diamond(cx, cy, r * 0.4, withAlpha(theme.highlightColor, col.a));
}

// Illuminated divider: rules fading outward from a quatrefoil boss flanked by
// gold diamonds — the ornament row under titles (menu, pause, death, victory).
fn ornamentDivider(cx: i32, y: i32, halfW: i32, a: u8) void {
    rl.drawRectangleGradientH(cx - halfW, y - 1, halfW - 34, 2, withAlpha(theme.goldColor, 0), withAlpha(theme.goldColor, a));
    rl.drawRectangleGradientH(cx + 34, y - 1, halfW - 34, 2, withAlpha(theme.goldColor, a), withAlpha(theme.goldColor, 0));
    fleuron(cx, y, 6, withAlpha(theme.goldColor, a));
    diamond(cx - 26, y, 3.5, withAlpha(theme.goldColor, mathx.u8f(fi(a) * 0.8)));
    diamond(cx + 26, y, 3.5, withAlpha(theme.goldColor, mathx.u8f(fi(a) * 0.8)));
}

// Tooled stamping: an alternating diamond/dot chain — the leather-punch border
// run just inside a big panel's brass liner.
fn stampedRow(x: i32, y: i32, w: i32, a: u8) void {
    const step: i32 = 26;
    var sx = x + @divTrunc(@mod(w, step), 2);
    var k: i32 = 0;
    while (sx <= x + w) : (sx += step) {
        if (@mod(k, 2) == 0) {
            diamond(sx, y, 2.6, withAlpha(theme.trimColor, a));
        } else {
            rl.drawCircleV(.{ .x = fi(sx), .y = fi(y) }, 1.3, withAlpha(theme.trimColor, a));
        }
        k += 1;
    }
}

// Oiled-walnut slab: lit-top gradient plus stateless grain streaks (golden-ratio
// scatter, like emberField). `alpha` keeps in-combat slabs translucent.
fn woodPanel(x: i32, y: i32, w: i32, h: i32, alpha: u8) void {
    rl.drawRectangleGradientV(x, y, w, h, withAlpha(theme.woodLight, alpha), withAlpha(theme.woodDark, alpha));
    const n = @max(@divTrunc(h, 7), 4);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const f = fi(i);
        const yy = y + 2 + @as(i32, @intFromFloat(@mod(f * 0.618, 1.0) * fi(h - 4)));
        // Streaks fade out at both ends (no hard terminations) so they read as grain
        // sheen, not ruled ledger lines.
        const inset = 4 + @as(i32, @intFromFloat(@mod(f * 0.377, 1.0) * 30));
        const gw = w - inset * 2;
        const half = @divTrunc(gw, 2);
        const dark = @mod(i, 3) != 0;
        const ga = mathx.u8f((if (dark) @as(f32, 42) else 20) * fi(alpha) / 255);
        const col = if (dark) rl.Color.black else rgba(214, 160, 96, 255);
        rl.drawRectangleGradientH(x + inset, yy, half, 1, withAlpha(col, 0), withAlpha(col, ga));
        rl.drawRectangleGradientH(x + inset + half, yy, gw - half, 1, withAlpha(col, ga), withAlpha(col, 0));
    }
    // Age: scorch creeping in from every edge, and a few old stains in the field
    // (scissored — soft ellipses must never bleed past the slab).
    const ea = mathx.u8f(60 * fi(alpha) / 255);
    rl.drawRectangleGradientV(x, y, w, 16, withAlpha(rl.Color.black, ea), withAlpha(rl.Color.black, 0));
    rl.drawRectangleGradientV(x, y + h - 16, w, 16, withAlpha(rl.Color.black, 0), withAlpha(rl.Color.black, ea));
    rl.drawRectangleGradientH(x, y, 24, h, withAlpha(rl.Color.black, ea), withAlpha(rl.Color.black, 0));
    rl.drawRectangleGradientH(x + w - 24, y, 24, h, withAlpha(rl.Color.black, 0), withAlpha(rl.Color.black, ea));
    rl.beginScissorMode(x, y, w, h);
    var b: i32 = 0;
    while (b < 4) : (b += 1) {
        const bf = fi(b) + fi(x) * 0.05;
        const bx = x + @as(i32, @intFromFloat(@mod(bf * 0.618 + 0.13, 1.0) * fi(w)));
        const by = y + @as(i32, @intFromFloat(@mod(bf * 0.414 + 0.29, 1.0) * fi(h)));
        rl.drawEllipse(bx, by, 14 + @mod(bf, 1.0) * 22, 8 + @mod(bf * 0.7, 1.0) * 12, withAlpha(rl.Color.black, mathx.u8f(13 * fi(alpha) / 255)));
    }
    rl.endScissorMode();
}

// Riveted iron frame: hammered outer band, faint bevel catch, hand-forged brass
// liner that breathes with the candlelight, studded corner plates, scrollwork
// curling out from behind them. The character panel wears the full set.
fn ironFrame(x: i32, y: i32, w: i32, h: i32) void {
    // Molding stack (library dialect): dark iron stroke, waxed hardwood band with
    // a varnish highlight, then the hand-forged brass liner breathing inside.
    rl.drawRectangleLinesEx(.{ .x = fi(x), .y = fi(y), .width = fi(w), .height = fi(h) }, 2, theme.ironDark);
    rl.drawRectangleLinesEx(.{ .x = fi(x + 2), .y = fi(y + 2), .width = fi(w - 4), .height = fi(h - 4) }, 4, theme.woodMid);
    rl.drawRectangleLinesEx(.{ .x = fi(x + 6), .y = fi(y + 6), .width = fi(w - 12), .height = fi(h - 12) }, 1, withAlpha(theme.woodBevel, 210));
    forgedRect(x + 9, y + 9, w - 18, h - 18, withAlpha(theme.trimColor, flickA(185, x)));
    const P: i32 = 20;
    for ([_][2]i32{ .{ x, y }, .{ x + w - P, y }, .{ x, y + h - P }, .{ x + w - P, y + h - P } }) |c| {
        rl.drawRectangle(c[0], c[1], P, P, theme.ironDark);
        hammered(c[0], c[1], P, P, 4);
        rl.drawRectangleLines(c[0], c[1], P, P, withAlpha(theme.ironLight, 150));
        rivet(c[0] + @divTrunc(P, 2), c[1] + @divTrunc(P, 2), 3.4);
    }
    scrollCorner(x + 17, y + 17, 0, 150);
    scrollCorner(x + w - 17, y + 17, 1, 150);
    scrollCorner(x + w - 17, y + h - 17, 2, 150);
    scrollCorner(x + 17, y + h - 17, 3, 150);
    stampedRow(x + 60, y + 15, w - 120, 90);
    stampedRow(x + 60, y + h - 15, w - 120, 90);
}

// ---- Gamepad glyphs ----
// Little controller-button graphics. The pad is the primary input, so the HUD names
// every action with the button that performs it — not a keyboard key. Xbox lettering
// and colors, since every prompt already reads A/B/X/Y. Glyphs center on (cx, cy);
// `r` is a radius/half-extent in px. slotGlyph() maps a skill slot to its button so the
// drawn glyph is driven by input.slotPad — it can never disagree with what fires.
const PadBtn = enum { a, b, x, y };
const Dir = enum { up, down, left, right, leftright, updown };

fn padBtnColor(btn: PadBtn) rl.Color {
    return switch (btn) {
        .a => rgba(94, 178, 66, 255), // green
        .b => rgba(214, 62, 52, 255), // red
        .x => rgba(46, 120, 205, 255), // blue
        .y => rgba(234, 190, 58, 255), // amber
    };
}
fn padBtnLetter(btn: PadBtn) [:0]const u8 {
    return switch (btn) {
        .a => "A",
        .b => "B",
        .x => "X",
        .y => "Y",
    };
}

// Center a short glyph label on (cx, cy). Vertical factor tuned to IM Fell's cap height;
// a 1px shadow gives the letter punch over a bright disc.
fn glyphLabel(s: [:0]const u8, cx: i32, cy: i32, size: i32, col: rl.Color) void {
    const w = textW(s, size);
    const y = cy - @as(i32, @intFromFloat(fsize(size) * 0.62));
    drawStr(s, cx - @divTrunc(w, 2) + 1, y + 1, size, rgba(0, 0, 0, 150));
    drawStr(s, cx - @divTrunc(w, 2), y, size, col);
}

// Round face button, library style: dark raised dome + a colored ring + the letter
// in the button's hue. The color names the button; the body stays in the palette
// (a full colored disc read as modern plastic against the wood-and-brass chrome).
fn padFace(cx: i32, cy: i32, r: i32, btn: PadBtn) void {
    const col = padBtnColor(btn);
    const cv = rl.Vector2.init(fi(cx), fi(cy));
    rl.drawCircleV(cv, fi(r) + 1.5, withAlpha(theme.ink, 235)); // seat shadow
    rl.drawCircleV(cv, fi(r), rgba(27, 23, 19, 255)); // iron body
    rl.drawCircleV(.{ .x = fi(cx), .y = fi(cy) - fi(r) * 0.16 }, fi(r) * 0.80, rgba(40, 34, 28, 255)); // raised dome
    rl.drawCircleLines(cx, cy, fi(r) - 1, withAlpha(col, 245)); // colored ring...
    rl.drawCircleLines(cx, cy, fi(r) - 2.2, withAlpha(col, 150)); // ...with a soft echo
    const sz = @max(@divTrunc(r * 5, 4), 11);
    glyphLabel(padBtnLetter(btn), cx, cy, sz, lerpColor(col, rl.Color.white, 0.38));
}

// D-pad: a rounded iron tile with four chevrons; the requested direction(s) burn
// gilt, the rest stay dim (library glyph dialect — a tile reads cleaner than a
// cross at footer sizes). leftright/updown light a pair for "move" prompts.
fn padDpad(cx: i32, cy: i32, r: i32, dir: Dir) void {
    const gh = fi(r) * 2;
    const tile = rl.Rectangle{ .x = fi(cx) - fi(r) + 1, .y = fi(cy) - fi(r) + 1, .width = gh - 2, .height = gh - 2 };
    rl.drawRectangleRounded(tile, 0.35, 6, rgba(27, 23, 19, 255));
    rl.drawRectangleRoundedLinesEx(tile, 0.35, 6, 1, withAlpha(theme.trimColor, 150));
    const up = dir == .up or dir == .updown;
    const dn = dir == .down or dir == .updown;
    const lf = dir == .left or dir == .leftright;
    const rt = dir == .right or dir == .leftright;
    const cw = gh * 0.16;
    const off = gh * 0.30;
    const tip = gh * 0.40;
    const xf = fi(cx);
    const yf = fi(cy);
    const on = theme.goldColor;
    const dim = withAlpha(theme.trimColor, 110);
    rl.drawLineEx(.{ .x = xf - cw, .y = yf - off }, .{ .x = xf, .y = yf - tip }, 1.6, if (up) on else dim);
    rl.drawLineEx(.{ .x = xf, .y = yf - tip }, .{ .x = xf + cw, .y = yf - off }, 1.6, if (up) on else dim);
    rl.drawLineEx(.{ .x = xf - cw, .y = yf + off }, .{ .x = xf, .y = yf + tip }, 1.6, if (dn) on else dim);
    rl.drawLineEx(.{ .x = xf, .y = yf + tip }, .{ .x = xf + cw, .y = yf + off }, 1.6, if (dn) on else dim);
    rl.drawLineEx(.{ .x = xf - off, .y = yf - cw }, .{ .x = xf - tip, .y = yf }, 1.6, if (lf) on else dim);
    rl.drawLineEx(.{ .x = xf - tip, .y = yf }, .{ .x = xf - off, .y = yf + cw }, 1.6, if (lf) on else dim);
    rl.drawLineEx(.{ .x = xf + off, .y = yf - cw }, .{ .x = xf + tip, .y = yf }, 1.6, if (rt) on else dim);
    rl.drawLineEx(.{ .x = xf + tip, .y = yf }, .{ .x = xf + off, .y = yf + cw }, 1.6, if (rt) on else dim);
}

// The dark rounded-pill chrome shared by the controller pictograms (menu + bumper).
fn padPill(rect: rl.Rectangle) void {
    rl.drawRectangleRounded(rect, 0.6, 6, rgba(34, 29, 24, 235));
    rl.drawRectangleRoundedLinesEx(rect, 0.6, 6, 1, withAlpha(theme.trimColor, 160));
}

// Start-button pictogram: a bumper pill wearing the three-line menu icon (no
// letter — the physical button has none).
fn padMenu(cx: i32, cy: i32) void {
    const w: i32 = 24;
    const h: i32 = 16;
    const rect = rl.Rectangle{ .x = fi(cx - @divTrunc(w, 2)), .y = fi(cy - @divTrunc(h, 2)), .width = fi(w), .height = fi(h) };
    padPill(rect);
    var i: i32 = -1;
    while (i <= 1) : (i += 1) {
        const ly = fi(cy) + fi(i) * 3.5;
        rl.drawLineEx(.{ .x = fi(cx) - 5, .y = ly }, .{ .x = fi(cx) + 5, .y = ly }, 1.5, rgba(226, 210, 180, 245));
    }
}

// Shoulder-bumper pill (L1 / R1), sized to its label and centered on (cx, cy).
fn padBumper(cx: i32, cy: i32, label: [:0]const u8) void {
    const size: i32 = 12;
    const w = textW(label, size) + 12;
    const h: i32 = 18;
    const r = rl.Rectangle{ .x = fi(cx - @divTrunc(w, 2)), .y = fi(cy - @divTrunc(h, 2)), .width = fi(w), .height = fi(h) };
    padPill(r);
    glyphLabel(label, cx, cy, size, rgba(226, 210, 180, 245));
}

// The controller button that fires skill slot `i`, drawn at (cx, cy). Mirrors
// input.slotPad so the badge on a slot always matches the button that triggers it.
fn slotGlyph(i: usize, cx: i32, cy: i32, r: i32) void {
    switch (input.slotPad[i]) {
        .face_a => padFace(cx, cy, r, .a),
        .face_x => padFace(cx, cy, r, .x),
        .face_y => padFace(cx, cy, r, .y),
        .face_b => padFace(cx, cy, r, .b),
        .l1 => padBumper(cx, cy, "L1"),
        .r1 => padBumper(cx, cy, "R1"),
    }
}

// One "[glyph] label" prompt used by the character-screen footers. The glyph is the
// button; the label says what it does — no key names.
const Hint = struct {
    glyph: union(enum) { face: PadBtn, dpad: Dir, bumper: [:0]const u8, menu: void },
    label: [:0]const u8,
};

fn hintGlyphW(h: Hint, gr: i32) i32 {
    return switch (h.glyph) {
        .face, .dpad => gr * 2,
        .bumper => |b| textW(b, 12) + 12,
        .menu => 24,
    };
}

fn drawHintGlyph(h: Hint, cx: i32, cy: i32, gr: i32) void {
    switch (h.glyph) {
        .face => |b| padFace(cx, cy, gr, b),
        .dpad => |d| padDpad(cx, cy, gr, d),
        .bumper => |b| padBumper(cx, cy, b),
        .menu => padMenu(cx, cy),
    }
}

// Draw a centered row of hints on the vertical center line `cy`.
fn hintRow(hints: []const Hint, cy: i32, size: i32, col: rl.Color) void {
    const gr: i32 = 9;
    const gap: i32 = 7; // glyph → its label
    const pad: i32 = 26; // hint → next hint
    var total: i32 = 0;
    for (hints, 0..) |h, i| {
        total += hintGlyphW(h, gr) + gap + textW(h.label, size);
        if (i + 1 < hints.len) total += pad;
    }
    const ty = cy - @as(i32, @intFromFloat(fsize(size) * 0.5));
    var x = @divTrunc(sw(), 2) - @divTrunc(total, 2);
    const x0 = x;
    for (hints) |h| {
        const gw = hintGlyphW(h, gr);
        drawHintGlyph(h, x + @divTrunc(gw, 2), cy, gr);
        x += gw + gap;
        text(h.label, x, ty, size, col);
        x += textW(h.label, size) + pad;
    }
    // Diamond termini stitch the strip closed (library footer dialect).
    const termA: u8 = @intCast(@as(u16, 150) * @as(u16, col.a) / 255);
    diamond(x0 - 16, cy, 2.8, withAlpha(theme.trimColor, termA));
    diamond(x - pad + 16, cy, 2.8, withAlpha(theme.trimColor, termA));
}

// Top-level dispatcher: called once per frame after the 3D pass.
pub fn draw(g: *Game) void {
    ensureFonts();
    chromeT = g.elapsed;
    switch (g.scene) {
        .menu => {
            vignette();
            drawMenu(g);
        },
        .playing => {
            vignette();
            drawHUD(g);
            if (g.sheetOpen) drawCharScreen(g);
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

// Level-up bloom state: the XP channel flares when Level ticks up (transition,
// not state — same reasoning as the slot ready-bloom).
var xpPrevLevel: i32 = -1;
var xpBloom: f32 = 0;

// Damage ghost on the enemy bar (one plate shows at a time, so one slot): when HP
// drops, the lost slice holds hot for a beat, then drains into the fill edge.
var plateGhostID: i32 = -1;
var plateGhostHP: f32 = 0;
var platePrevHP: f32 = 0;
var plateGhostHold: f32 = 0;
const GHOST_HOLD = 0.22;

// Top-center enemy plate (PoE/D2 style): foe's name over one wide thin bar — never
// floating bars over heads.
fn drawEnemyPlate(g: *Game) void {
    const m = pickEnemyPlate(g) orelse return;
    const dt = rl.getFrameTime();
    if (m.id != plateGhostID) {
        plateGhostID = m.id;
        plateGhostHP = m.HP;
        platePrevHP = m.HP;
        plateGhostHold = 0;
    }
    if (m.HP < platePrevHP - 0.01) plateGhostHold = GHOST_HOLD; // fresh hit re-arms the hold
    platePrevHP = m.HP;
    if (plateGhostHold > 0) {
        plateGhostHold -= dt;
    } else {
        plateGhostHP += (m.HP - plateGhostHP) * (1 - @exp(-dt * 8.0));
    }
    if (m.HP >= plateGhostHP) plateGhostHP = m.HP; // heals snap, only damage trails
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
    // Iron-edged plaque behind name + bar(s): ink core so it reads over any scene,
    // finials on the side edges so it hangs like a mounted nameplate.
    const plw = bw + 36;
    const plh = by - 8 + bh + 10 + stunPad;
    rl.drawRectangle(bx - 18, 8, plw, plh, withAlpha(theme.ink, 175));
    rl.drawRectangleLines(bx - 18, 8, plw, plh, withAlpha(theme.ironDark, 225));
    forgedRect(bx - 17, 9, plw - 2, plh - 2, withAlpha(theme.trimColor, 80));
    rivet(bx - 12, 14, 2.2);
    rivet(bx - 18 + plw - 6, 14, 2.2);
    if (boss) {
        quatrefoil(bx - 18, 8 + @divTrunc(plh, 2), 7, 245);
        quatrefoil(bx - 18 + plw, 8 + @divTrunc(plh, 2), 7, 245);
    } else {
        finial(bx - 18, 8 + @divTrunc(plh, 2), 5, 230);
        finial(bx - 18 + plw, 8 + @divTrunc(plh, 2), 5, 230);
    }
    hangStrap(bx - 18 + 26, 8);
    hangStrap(bx - 18 + plw - 26, 8);
    var nbuf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&nbuf, "{s}", .{m.name.slice()}) catch "";
    centered(name, 14, size, if (boss) rgba(255, 185, 205, 255) else rgba(240, 225, 205, 255));
    if (boss) {
        // A boss earns gold diamonds flanking the name.
        const nw = textW(name, size);
        const dy = 14 + @as(i32, @intFromFloat(fsize(size) * 0.55));
        diamond(cx - @divTrunc(nw, 2) - 16, dy, 4, withAlpha(theme.goldColor, 220));
        diamond(cx + @divTrunc(nw, 2) + 16, dy, 4, withAlpha(theme.goldColor, 220));
    }
    barBacking(bx, by, bw, bh);
    const fillCol = if (boss) rgba(225, 45, 105, 255) else rgba(200, 48, 40, 255);
    barFill(bx, by, bw, bh, m.HP / m.MaxHP, fillCol, 0.3, 210);
    // Ghost slice: hot parchment between the live fill and where HP just was.
    const hfrac = clampF(m.HP / m.MaxHP, 0, 1);
    const gfrac = clampF(plateGhostHP / m.MaxHP, 0, 1);
    if (gfrac > hfrac + 0.002) {
        const gx = bx + @as(i32, @intFromFloat(fi(bw) * hfrac));
        const gw = @as(i32, @intFromFloat(fi(bw) * (gfrac - hfrac)));
        rl.drawRectangle(gx, by, @max(gw, 1), bh, withAlpha(rgba(255, 206, 128, 255), 235));
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
            barFill(bx, sy, bw, sbh, m.stunFill, rgba(240, 205, 90, 255), 0.35, 0);
        }
        forgedRect(bx - 2, sy - 2, bw + 4, sbh + 4, withAlpha(theme.trimColor, 110));
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
const sheetDim = rgba(206, 194, 172, 255); // dimmer parchment for subtitles / hints / notes

// Bright selection gold: the active tab label and the highlighted menu row share it.
const selectedGold = rgba(255, 228, 160, 255);
// Pulsing prompt gold on the death / victory screens (alpha animates per-frame).
const hintPulseGold = rgba(255, 230, 160, 255);

// Allocatable row: label left, value right, green "+" when a point can be spent,
// warm highlight box when it's the cursor.
fn sheetAllocRow(x: i32, y: i32, w: i32, label: [:0]const u8, val: [:0]const u8, selected: bool, canAlloc: bool) void {
    if (selected) {
        rl.drawRectangle(x - 8, y - 4, w + 16, 25, withAlpha(rgba(180, 140, 70, 255), 70));
        // Candlelight sweeps the chosen row on a shared slow clock (position, not
        // a pulse — one light crossing the ledger, dark beat between passes).
        const per: f32 = 3.8;
        const swp = @mod(chromeT, per) / per;
        const sweepX = x - 8 - 120 + @as(i32, @intFromFloat(swp * fi(w + 16 + 240)));
        rl.beginScissorMode(x - 8, y - 4, w + 16, 25);
        rl.drawRectangleGradientH(sweepX, y - 4, 60, 25, withAlpha(theme.highlightColor, 0), withAlpha(theme.highlightColor, 30));
        rl.drawRectangleGradientH(sweepX + 60, y - 4, 60, 25, withAlpha(theme.highlightColor, 30), withAlpha(theme.highlightColor, 0));
        rl.endScissorMode();
        forgedRect(x - 8, y - 4, w + 16, 25, withAlpha(theme.trimColor, 150));
    }
    text(label, x, y, 18, sheetInk);
    const showPlus = selected and canAlloc;
    const vw = textW(val, 18);
    const plusGap: i32 = if (showPlus) 24 else 0;
    text(val, x + w - vw - plusGap, y, 18, rgba(245, 235, 210, 255));
    if (showPlus) text("+", x + w - 16, y - 1, 20, rgba(150, 230, 150, 255));
}

// One read-only derived-stat row, hand-set ledger leader dots running label → figure.
fn sheetStatRow(x: i32, y: i32, w: i32, label: [:0]const u8, val: [:0]const u8) void {
    text(label, x, y, 18, rgba(196, 186, 168, 255));
    const vw = textW(val, 18);
    var dx = x + textW(label, 18) + 12;
    while (dx < x + w - vw - 12) : (dx += 9) {
        rl.drawCircleV(.{ .x = fi(dx), .y = fi(y) + 15 }, 0.8, withAlpha(theme.labelColor, 70));
    }
    text(val, x + w - vw, y, 18, sheetInk);
}

// A derived-stat row whose value is formatted inline, then advances the running `yy`.
// One scratch buffer here instead of a fresh named buffer per row at the call site.
fn sheetStatF(x: i32, yy: *i32, w: i32, rowH: i32, label: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [48]u8 = undefined;
    sheetStatRow(x, yy.*, w, label, std.fmt.bufPrintZ(&buf, fmt, args) catch "");
    yy.* += rowH;
}

// The character screen: shared chrome + a Stats/Skills tab strip, then the active page.
// Controller-first — Select/C opens, L1/R1 flip pages, the d-pad navigates, A confirms,
// B closes (see updateCharScreen). Mouse works too but is the secondary path.
fn drawCharScreen(g: *Game) void {
    const W = sw();
    const H = sh();
    rl.drawRectangle(0, 0, W, H, withAlpha(rgba(6, 4, 8, 255), 200)); // dim the frozen world
    radialWash(withAlpha(theme.ink, 120), 1.02); // and darken toward the corners — candlelit focus

    const pw: i32 = 760;
    const ph: i32 = 540;
    const px = @divTrunc(W - pw, 2);
    const py = @divTrunc(H - ph, 2);
    // Stacked drop shadow lifts the panel off the scene (widest + faintest first).
    rl.drawRectangleRounded(.{ .x = fi(px + 10), .y = fi(py + 14), .width = fi(pw), .height = fi(ph) }, 0.03, 6, withAlpha(rl.Color.black, 34));
    rl.drawRectangleRounded(.{ .x = fi(px + 6), .y = fi(py + 8), .width = fi(pw), .height = fi(ph) }, 0.03, 6, withAlpha(rl.Color.black, 56));
    rl.drawRectangleRounded(.{ .x = fi(px + 2), .y = fi(py + 3), .width = fi(pw), .height = fi(ph) }, 0.03, 6, withAlpha(rl.Color.black, 72));
    woodPanel(px, py, pw, ph, 250);
    ironFrame(px, py, pw, ph);
    quatrefoil(px + @divTrunc(pw, 2), py, 11, 255);
    quatrefoil(px + @divTrunc(pw, 2), py + ph, 11, 255);

    drawCharTabs(g, py + 18);
    switch (g.charTab) {
        .stats => drawStatsTab(g, px, py, pw, ph),
        .skills => drawSkillsTab(g, px, py, pw, ph),
    }
}

// The Stats/Skills tab strip (doubles as the panel title). Active tab is bright with a
// gold underline; L1/R1 bumpers flank the strip so the page-flip button is shown right
// where the pages are. A mouse click switches too (secondary).
fn drawCharTabs(g: *Game, cy: i32) void {
    const W = sw();
    const Tab = struct { t: gamemod.CharTab, label: [:0]const u8 };
    const tabs = [_]Tab{ .{ .t = .stats, .label = "Stats" }, .{ .t = .skills, .label = "Skills" } };
    // Pin the tab list 1:1 with CharTab so a new tab can't silently vanish from the strip.
    comptime std.debug.assert(tabs.len == @typeInfo(gamemod.CharTab).@"enum".fields.len);
    const size: i32 = 30;
    const gap: i32 = 44;
    var total: i32 = gap * (@as(i32, tabs.len) - 1);
    for (tabs) |tb| total += textW(tb.label, size);
    const xStart = @divTrunc(W, 2) - @divTrunc(total, 2);
    var x = xStart;
    const mouse = rl.getMousePosition();
    for (tabs) |tb| {
        const tw = textW(tb.label, size);
        const active = g.charTab == tb.t;
        const r = rl.Rectangle{ .x = fi(x - 10), .y = fi(cy - 4), .width = fi(tw + 20), .height = 42 };
        if (rl.checkCollisionPointRec(mouse, r) and rl.isMouseButtonPressed(.left)) g.charTab = tb.t;
        engraved(tb.label, x, cy, size, if (active) selectedGold else rgba(178, 166, 146, 200));
        if (active) {
            forgedH(x, cy + 36, tw, withAlpha(theme.goldColor, 230));
            forgedH(x, cy + 38, tw, withAlpha(theme.goldColor, 160));
            diamond(x - 7, cy + 37, 3, withAlpha(theme.goldColor, 210));
            diamond(x + tw + 7, cy + 37, 3, withAlpha(theme.goldColor, 210));
        }
        x += tw + gap;
    }
    const cyMid = cy + 16;
    padBumper(xStart - 34, cyMid, "L1");
    padBumper(xStart + total + 34, cyMid, "R1");
}

// The Skills page: a row of six button-slots (your loadout) over a pool of every skill —
// a glanceable spellbook. Pick a button (left/right), drop into the pool (down), and A
// binds the focused skill onto that button (A on the skill already there clears it). Each
// placed skill wears the badge of its button, so at a glance you see what's bound where.
// Mouse mirrors it (hover focuses; left-click binds/toggles; right-click clears). Persists
// on close.
fn drawSkillsTab(g: *Game, px: i32, py: i32, pw: i32, ph: i32) void {
    const p = &g.p;
    engravedCentered("Skill Loadout", py + 56, 24, sheetGold);
    centered("Pick a button, then choose its skill from the pool. Changes save automatically.", py + 90, 14, withAlpha(sheetDim, 220));

    const mouse = rl.getMousePosition();
    const md = rl.getMouseDelta();
    const mouseMoving = (md.x != 0 or md.y != 0);

    // ── Button-slot row (the loadout) ──
    const slots: i32 = playermod.SKILL_SLOTS;
    const ssize: i32 = 62;
    const sgap: i32 = 26;
    const srowW: i32 = slots * ssize + (slots - 1) * sgap;
    const sx0 = px + @divTrunc(pw - srowW, 2);
    const sy = py + 152;
    const glyphY = sy - 20; // button glyph rides above each well
    var sx = sx0;
    var i: usize = 0;
    while (i < playermod.SKILL_SLOTS) : (i += 1) {
        const r = rl.Rectangle{ .x = fi(sx), .y = fi(sy), .width = fi(ssize), .height = fi(ssize) };
        const hot = rl.checkCollisionPointRec(mouse, r);
        if (hot and mouseMoving) {
            g.skillZone = .slots;
            g.skillSel = @intCast(i);
        }
        if (hot) {
            if (rl.isMouseButtonPressed(.left)) {
                g.skillZone = .slots;
                g.skillSel = @intCast(i); // click just focuses the button; pick its skill below
            }
            if (rl.isMouseButtonPressed(.right)) p.bar.assign(i, null); // clear it
        }
        const chosen = g.skillSel == @as(i32, @intCast(i));
        const focused = chosen and g.skillZone == .slots;
        // Button glyph above the well; a warm disc marks the chosen button — bright while the
        // cursor is up here, faint while you're browsing the pool (so you still see the target).
        const gcx = sx + @divTrunc(ssize, 2);
        if (chosen) rl.drawCircleV(.{ .x = fi(gcx), .y = fi(glyphY) }, 18, withAlpha(theme.highlightColor, if (focused) 110 else 50));
        slotGlyph(i, gcx, glyphY, 13);
        drawSkillSlot(sx, sy, ssize, null, p.bar.slots[i], null, 2.0);
        if (focused) {
            rl.drawRectangleRoundedLinesEx(r, SLOT_ROUND, SLOT_SEG, 3, withAlpha(theme.highlightColor, 235));
        } else if (chosen) {
            rl.drawRectangleRoundedLinesEx(r, SLOT_ROUND, SLOT_SEG, 2, withAlpha(theme.highlightColor, 130));
        } else if (hot) {
            rl.drawRectangleRoundedLinesEx(r, SLOT_ROUND, SLOT_SEG, 2, withAlpha(theme.highlightColor, 120));
        }
        const nm: [:0]const u8 = if (p.bar.slots[i]) |s| s.label() else "empty";
        textCenteredIn(nm, sx, ssize, sy + ssize + 6, 13, if (p.bar.slots[i] != null) sheetInk else rgba(150, 140, 128, 200));
        sx += ssize + sgap;
    }

    // ── "Available Skills" heading, with flanking rules ──
    const hdrY = sy + ssize + 34;
    const hdr = "Available Skills";
    const hw = textW(hdr, 15);
    centered(hdr, hdrY, 15, withAlpha(sheetGold, 230));
    const hcy = hdrY + @as(i32, @intFromFloat(fsize(15) * 0.5));
    const ruleHalf = @divTrunc(pw - 96, 2);
    const gapToText = @divTrunc(hw, 2) + 14;
    rl.drawRectangle(px + 48, hcy, ruleHalf - gapToText, 1, withAlpha(theme.trimColor, 90));
    rl.drawRectangle(@divTrunc(sw(), 2) + gapToText, hcy, ruleHalf - gapToText, 1, withAlpha(theme.trimColor, 90));
    diamond(px + 48, hcy, 2.2, withAlpha(theme.trimColor, 130));
    diamond(px + pw - 48, hcy, 2.2, withAlpha(theme.trimColor, 130));
    diamond(@divTrunc(sw(), 2) - gapToText, hcy, 3, withAlpha(theme.trimColor, 150));
    diamond(@divTrunc(sw(), 2) + gapToText, hcy, 3, withAlpha(theme.trimColor, 150));

    // ── Skill pool grid ──
    const cols: i32 = gamemod.SKILL_POOL_COLS;
    const pmargin: i32 = 40;
    const innerW = pw - pmargin * 2;
    const cellGap: i32 = 12;
    const cellW = @divTrunc(innerW - (cols - 1) * cellGap, cols);
    const cellH: i32 = 70;
    const rowGap: i32 = 12;
    const poolX0 = px + pmargin;
    const poolY0 = hdrY + 32;
    var j: usize = 0;
    while (j < playermod.Skill.count) : (j += 1) {
        const s = playermod.Skill.all[j];
        const ji: i32 = @intCast(j);
        const cx = poolX0 + @mod(ji, cols) * (cellW + cellGap);
        const cy = poolY0 + @divTrunc(ji, cols) * (cellH + rowGap);
        const cell = rl.Rectangle{ .x = fi(cx), .y = fi(cy), .width = fi(cellW), .height = fi(cellH) };
        const hot = rl.checkCollisionPointRec(mouse, cell);
        if (hot and mouseMoving) {
            g.skillZone = .pool;
            g.skillPoolSel = ji;
        }
        const boundSlot = p.bar.slotOf(s);
        if (hot) {
            if (rl.isMouseButtonPressed(.left)) {
                g.skillZone = .pool;
                g.skillPoolSel = ji;
                const slot: usize = @intCast(g.skillSel);
                p.bar.assign(slot, if (p.bar.slots[slot] == s) null else s); // toggle onto chosen button
            }
            if (rl.isMouseButtonPressed(.right)) {
                if (boundSlot) |bs| p.bar.assign(bs, null); // unbind from wherever it sits
            }
        }
        const focused = g.skillZone == .pool and g.skillPoolSel == ji;
        drawPoolChip(cell, s, boundSlot, focused);
    }

    // ── Blurb: what the focused thing does, in one friendly line ──
    const focusedSkill: ?playermod.Skill = switch (g.skillZone) {
        .slots => p.bar.slots[@intCast(g.skillSel)],
        .pool => playermod.Skill.all[@intCast(g.skillPoolSel)],
    };
    const blurbY = poolY0 + 2 * (cellH + rowGap) + 4;
    const blurb: [:0]const u8 = if (focusedSkill) |s| s.blurb() else "This button is unused. Drop a skill onto it from the pool below.";
    centered(blurb, blurbY, 15, rgba(214, 202, 180, 235));
    // Ledger-note flanks: hairlines ending in pips stitch the blurb into the page.
    const bw2 = textW(blurb, 15);
    const bcy = blurbY + 9;
    const lnW: i32 = 40;
    const bGap = @divTrunc(bw2, 2) + 16;
    rl.drawRectangle(@divTrunc(sw(), 2) - bGap - lnW, bcy, lnW, 1, withAlpha(theme.trimColor, 80));
    rl.drawRectangle(@divTrunc(sw(), 2) + bGap, bcy, lnW, 1, withAlpha(theme.trimColor, 80));
    diamond(@divTrunc(sw(), 2) - bGap - lnW, bcy, 2.2, withAlpha(theme.trimColor, 120));
    diamond(@divTrunc(sw(), 2) + bGap + lnW, bcy, 2.2, withAlpha(theme.trimColor, 120));

    // ── Footer — controller prompts (pad is primary; KBM mirrors). Prompts change with the
    // zone so the current gesture is always shown.
    if (g.skillZone == .slots) {
        const hints = [_]Hint{
            .{ .glyph = .{ .dpad = .leftright }, .label = "choose button" },
            .{ .glyph = .{ .dpad = .down }, .label = "to skill pool" },
            .{ .glyph = .{ .face = .b }, .label = "back" },
        };
        hintRow(&hints, py + ph - 30, 14, withAlpha(sheetDim, 235));
    } else {
        const hints = [_]Hint{
            .{ .glyph = .{ .dpad = .updown }, .label = "browse skills" },
            .{ .glyph = .{ .face = .a }, .label = "bind to button" },
            .{ .glyph = .{ .face = .b }, .label = "back to buttons" },
        };
        hintRow(&hints, py + ph - 30, 14, withAlpha(sheetDim, 235));
    }
}

// One pool chip: a rounded cell with the skill's emblem in a mini well, its name below,
// and — when the skill is bound — the badge of the button it lives on (top-right) over a
// warmer seat, so "already on the bar" and "which button" both read at a glance. The
// focused chip gets a gold frame.
fn drawPoolChip(cell: rl.Rectangle, s: playermod.Skill, boundSlot: ?usize, focused: bool) void {
    const bound = boundSlot != null;
    rl.drawRectangleRounded(cell, 0.16, 6, if (bound) rgba(30, 24, 18, 222) else rgba(15, 12, 12, 200));

    const cellX: i32 = @intFromFloat(cell.x);
    const cellY: i32 = @intFromFloat(cell.y);
    const cellW: i32 = @intFromFloat(cell.width);
    const wellSize: i32 = 40;
    const wellX = cellX + @divTrunc(cellW - wellSize, 2);
    drawSkillSlot(wellX, cellY + 8, wellSize, null, s, null, 1.45);

    // Name under the well; the long names drop a size so they don't clip the cell.
    const nm = s.label();
    const nsize: i32 = if (textW(nm, 13) > cellW - 8) 12 else 13;
    textCenteredIn(nm, cellX, cellW, cellY + 50, nsize, if (bound) sheetInk else withAlpha(sheetInk, 205));

    // Button badge (top-right) for a bound skill — the same glyph the slot row + HUD use.
    if (boundSlot) |bs| {
        const bcx = cellX + cellW - 15;
        const bcy = cellY + 14;
        rl.drawCircleV(.{ .x = fi(bcx), .y = fi(bcy) }, 12, rgba(10, 8, 7, 210)); // seat under the badge
        slotGlyph(bs, bcx, bcy, 9);
    }

    if (focused) {
        rl.drawRectangleRoundedLinesEx(cell, 0.16, 6, 3, withAlpha(theme.highlightColor, 235));
    } else {
        rl.drawRectangleRoundedLinesEx(cell, 0.16, 6, 1, withAlpha(theme.trimColor, if (bound) 150 else 80));
    }
}

// The Stats page (attributes/skills allocation + derived readout) — the former sheet.
fn drawStatsTab(g: *Game, px: i32, py: i32, pw: i32, ph: i32) void {
    const p = &g.p;
    var hbuf: [128]u8 = undefined;
    const head = std.fmt.bufPrintZ(&hbuf, "Level {d}    Attribute Points: {d}    Skill Points: {d}", .{ p.Level, p.attrPoints, p.skillPoints }) catch "";
    centered(head, py + 66, 18, rgba(214, 199, 178, 255));

    const colY = py + 106;
    const leftX = px + 44;
    const colW = @divTrunc(pw, 2) - 72;
    const rightX = px + @divTrunc(pw, 2) + 28;
    const rowH: i32 = 30;

    // Ledger divider between the allocatable and derived columns.
    rl.drawRectangle(px + @divTrunc(pw, 2) - 10, colY - 4, 1, ph - (colY - py) - 62, withAlpha(theme.trimColor, 60));

    // ── Left: attributes, then skills (allocatable) ──
    engraved("Attributes", leftX, colY, 22, sheetGold);
    diamond(leftX - 14, colY + 13, 3.5, withAlpha(theme.trimColor, 200));
    var vbuf: [24]u8 = undefined;
    for (stats.Attribs.order, 0..) |k, i| {
        const y = colY + 32 + @as(i32, @intCast(i)) * rowH;
        const sel = g.sheetSel == @as(i32, @intCast(i));
        const val = std.fmt.bufPrintZ(&vbuf, "{d}", .{p.attribs.get(k)}) catch "";
        sheetAllocRow(leftX, y, colW, stats.Attribs.label(k), val, sel, p.attrPoints > 0);
    }

    const skHdrY = colY + 32 + 6 * rowH + 14;
    engraved("Skills", leftX, skHdrY, 22, sheetGold);
    diamond(leftX - 14, skHdrY + 13, 3.5, withAlpha(theme.trimColor, 200));
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
        text(stats.Attribs.note(k), leftX, noteY, 16, withAlpha(sheetDim, 235));
    }

    // ── Right: derived stats (read-only totals) ──
    engraved("Defense", rightX, colY, 22, sheetGold);
    diamond(rightX - 14, colY + 13, 3.5, withAlpha(theme.trimColor, 200));
    var yy = colY + 32;
    sheetStatF(rightX, &yy, colW, rowH, "Life", "{d:.0}", .{p.MaxHP});
    sheetStatF(rightX, &yy, colW, rowH, "Mana", "{d:.0}", .{p.MaxMana});
    const drPct = stats.physReduction(p.def.armor, SHEET_DR_REF) * 100;
    sheetStatF(rightX, &yy, colW, rowH, "Armor", "{d:.0}  ({d:.0}% vs {d:.0})", .{ p.def.armor, drPct, SHEET_DR_REF });
    // Four resists, driven by the one canonical elemental list + its label.
    for (stats.DamageType.elementals) |rk| {
        var lb: [24]u8 = undefined;
        const ll = std.fmt.bufPrintZ(&lb, "{s} Res", .{rk.label()}) catch rk.label();
        sheetStatF(rightX, &yy, colW, rowH, ll, "{d:.0}%", .{p.def.resFor(rk) * 100});
    }

    yy += 12;
    engraved("Offense", rightX, yy, 22, sheetGold);
    diamond(rightX - 14, yy + 13, 3.5, withAlpha(theme.trimColor, 200));
    yy += 32;
    sheetStatF(rightX, &yy, colW, rowH, "Melee", "{d:.0}-{d:.0}", .{ p.MinDmg, p.MaxDmg });
    sheetStatF(rightX, &yy, colW, rowH, "Spell", "{d:.0}", .{p.spellDmg});
    sheetStatF(rightX, &yy, colW, rowH, "Crit", "{d:.0}%", .{p.derived.critChance * 100});
    sheetStatF(rightX, &yy, colW, rowH, "Cooldown Red.", "{d:.0}%", .{p.derived.cdrFrac * 100});

    // Footer — controller prompts only (the pad is the primary path).
    const hints = [_]Hint{
        .{ .glyph = .{ .dpad = .updown }, .label = "select" },
        .{ .glyph = .{ .face = .a }, .label = "spend point" },
        .{ .glyph = .{ .face = .b }, .label = "back" },
    };
    hintRow(&hints, py + ph - 28, 15, withAlpha(sheetDim, 235));
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

    // Mounting pedestal: the socket bolts to the screen's bottom sill — drawn
    // first so the globe overlaps its throat, with a flared riveted foot.
    const hb = sh();
    if (cy + radius + 34 > hb) {
        const half: i32 = 13;
        const pty = cy + radius - 8;
        rl.drawRectangle(cx - half, pty, half * 2, hb - pty, theme.ironDark);
        rl.drawRectangle(cx - half, pty, 2, hb - pty, withAlpha(theme.ironLight, 130));
        rl.drawRectangle(cx + half - 2, pty, 2, hb - pty, withAlpha(theme.ironLight, 55));
        rl.drawRectangle(cx - half - 8, hb - 7, half * 2 + 16, 7, theme.ironDark);
        forgedH(cx - half - 8, hb - 7, half * 2 + 16, withAlpha(theme.trimColor, 150));
        rivet(cx, hb - 16, 2.6);
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

    // Socket: heavy iron ring with a thin brass liner, studded at the diagonals so
    // it reads bolted onto the HUD.
    const cv = rl.Vector2.init(fi(cx), fi(cy));
    rl.drawRing(cv, rf, rf + 5, 0, 360, 48, rgba(32, 26, 20, 255));
    rl.drawRing(cv, rf + 4, rf + 5.5, 0, 360, 48, theme.trimColor);
    rl.drawRing(cv, rf - 1, rf + 1, 0, 360, 48, rgba(15, 12, 10, 255));
    for ([_]f32{ 45, 135, 225, 315 }) |deg| {
        const rad = mathx.radians(deg);
        rivet(cx + @as(i32, @intFromFloat(mathx.cosf(rad) * (rf + 2.5))), cy + @as(i32, @intFromFloat(mathx.sinf(rad) * (rf + 2.5))), 3.0);
    }
    // Claw prongs grip the glass at left, bottom, right (top stays clear for the
    // readout).
    for ([_]f32{ 0, 90, 180 }) |deg| {
        const rad = mathx.radians(deg);
        const pxf = fi(cx) + mathx.cosf(rad) * (rf - 1);
        const pyf = fi(cy) + mathx.sinf(rad) * (rf - 1);
        rl.drawPoly(.{ .x = pxf, .y = pyf }, 3, 7.5, deg + 180, theme.ironDark);
        rl.drawPoly(.{ .x = pxf, .y = pyf }, 3, 5.5, deg + 180, theme.trimColor);
    }

    // Low-resource smolder: stateless motes rise off the socket while the alarm
    // halo pulses — the orb reads as guttering, not just "under a threshold".
    if (frac < 0.28) {
        var ei: i32 = 0;
        while (ei < 5) : (ei += 1) {
            const iff = fi(ei);
            const ph = @mod(t * (0.5 + 0.13 * iff) + iff * 0.37, 1.0);
            const ex = fi(cx) + sinf(t * 2.1 + iff * 2.7) * rf * 0.5;
            const ey = fi(cy) - rf * 0.3 - ph * rf * 1.1;
            rl.drawCircleV(.{ .x = ex, .y = ey }, 1.5 + @mod(iff, 2.0), withAlpha(lerpColor(full, rl.Color.white, 0.3), mathx.u8f((1 - ph) * 150)));
        }
    }
}

// A HUD resource orb with its "cur/max" readout centered above it. One helper so the
// health and mana orbs can't drift on fill fraction, label format, or placement.
fn drawResourceOrb(cx: i32, orbY: i32, orbR: i32, cur: f32, max: f32, fill: rl.Color, socket: rl.Color, t: f32) void {
    drawOrb(cx, orbY, orbR, cur / max, fill, socket, t);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ @as(i32, @intFromFloat(cur)), @as(i32, @intFromFloat(max)) }) catch "";
    text(s, cx - @divTrunc(textW(s, 16), 2), orbY - 8, 16, theme.valueColor);
}

// ---- Skill bar + panel ----
// One vector emblem per skill (no gem art): steel dagger, orange flame, motion arc.
// Color lives here so the HUD bar and the loadout panel read alike.
fn skillColor(s: playermod.Skill) rl.Color {
    return switch (s) {
        .melee => rgba(200, 205, 215, 255), // steel
        .cleave => rgba(226, 232, 240, 255), // bright swept steel
        .throwing_knife => rgba(178, 188, 202, 255), // cool steel
        .firebolt => projectile.fireboltColor, // flame orange
        .ice_shard => projectile.iceShardColor, // glacial blue
        .lightning_nova => rgba(160, 200, 255, 255), // electric blue-white
        .toxic_flask => projectile.toxicColor, // poison green
        .dodge => rgba(120, 175, 235, 255), // dodge blue
        .health_potion => theme.healthColor, // crimson flask
        .mana_potion => theme.manaColor, // sapphire flask
    };
}

// Hand-inked emblems, authored at a ~25px extent about (cx, cy) and GL-scaled to
// the well (skillEmblemScaled). Triangles wind screen-CCW (apex first) like fleuron.
fn skillEmblem(cx: i32, cy: i32, s: playermod.Skill, col: rl.Color) void {
    const xf = fi(cx);
    const yf = fi(cy);
    const dark = lerpColor(col, rl.Color.black, 0.4);
    const lite = lerpColor(col, rl.Color.white, 0.45);
    const leather = rgba(58, 40, 26, 255);
    switch (s) {
        .melee => {
            // Arming sword: tapered blade with a fuller, guard with diamond tips,
            // wrapped grip, brass pommel.
            rl.drawTriangle(.{ .x = xf, .y = yf - 12 }, .{ .x = xf - 2, .y = yf - 7 }, .{ .x = xf + 2, .y = yf - 7 }, col);
            rl.drawRectangle(cx - 2, cy - 7, 4, 10, col);
            rl.drawRectangle(cx, cy - 7, 1, 9, dark);
            rl.drawRectangle(cx - 7, cy + 3, 14, 2, lerpColor(col, rl.Color.black, 0.2));
            diamond(cx - 7, cy + 4, 2, theme.trimColor);
            diamond(cx + 7, cy + 4, 2, theme.trimColor);
            rl.drawRectangle(cx - 1, cy + 5, 3, 5, leather);
            rl.drawRectangle(cx - 1, cy + 6, 3, 1, rgba(84, 58, 36, 255));
            rl.drawRectangle(cx - 1, cy + 8, 3, 1, rgba(84, 58, 36, 255));
            rl.drawCircleV(.{ .x = xf + 0.5, .y = yf + 11 }, 2.2, theme.trimColor);
        },
        .firebolt => {
            // Living flame: dark outer tongue, bright inner body, white heart, sparks.
            rl.drawCircleV(.{ .x = xf, .y = yf + 4 }, 6.5, lerpColor(col, rl.Color.black, 0.25));
            rl.drawTriangle(.{ .x = xf, .y = yf - 11 }, .{ .x = xf - 6, .y = yf + 3 }, .{ .x = xf + 6, .y = yf + 3 }, lerpColor(col, rl.Color.black, 0.25));
            rl.drawCircleV(.{ .x = xf + 0.5, .y = yf + 4 }, 4.4, col);
            rl.drawTriangle(.{ .x = xf + 1, .y = yf - 6 }, .{ .x = xf - 3, .y = yf + 4 }, .{ .x = xf + 4.5, .y = yf + 4 }, col);
            rl.drawCircleV(.{ .x = xf + 0.5, .y = yf + 4.5 }, 2.4, projectile.flameHeartColor);
            rl.drawCircleV(.{ .x = xf - 5, .y = yf - 4 }, 1.1, withAlpha(lite, 220));
            rl.drawCircleV(.{ .x = xf + 5.5, .y = yf - 7 }, 0.9, withAlpha(lite, 190));
        },
        .cleave => {
            // Sweeping cut: motion-trail arcs fading behind a leading blade wedge.
            rl.drawRing(.{ .x = xf, .y = yf + 1 }, 8.5, 10.5, -80, 60, 24, col);
            rl.drawRing(.{ .x = xf, .y = yf + 1 }, 5.5, 7, -70, 45, 20, withAlpha(col, 150));
            rl.drawRing(.{ .x = xf, .y = yf + 1 }, 3, 4, -60, 30, 16, withAlpha(col, 90));
            rl.drawTriangle(.{ .x = xf + 11, .y = yf - 8 }, .{ .x = xf + 4, .y = yf - 9.5 }, .{ .x = xf + 8, .y = yf - 1 }, lite);
        },
        .throwing_knife => {
            // Dagger canted 45° on the throw, speed lines trailing.
            rl.gl.rlPushMatrix();
            rl.gl.rlTranslatef(xf, yf, 0);
            rl.gl.rlRotatef(45, 0, 0, 1);
            rl.drawTriangle(.{ .x = 0, .y = -11 }, .{ .x = -2, .y = -6 }, .{ .x = 2, .y = -6 }, col);
            rl.drawRectangle(-2, -6, 4, 9, col);
            rl.drawRectangle(0, -6, 1, 8, dark);
            rl.drawRectangle(-5, 3, 10, 2, lerpColor(col, rl.Color.black, 0.25));
            rl.drawRectangle(-1, 5, 3, 4, leather);
            rl.gl.rlPopMatrix();
            rl.drawLineEx(.{ .x = xf - 9, .y = yf + 2 }, .{ .x = xf - 3, .y = yf + 8 }, 1.4, withAlpha(col, 120));
            rl.drawLineEx(.{ .x = xf - 11, .y = yf - 2 }, .{ .x = xf - 5, .y = yf + 4 }, 1.2, withAlpha(col, 80));
        },
        .ice_shard => {
            // Crystal shard: two facets, a spine glint, side slivers, one hard glint.
            rl.drawTriangle(.{ .x = xf, .y = yf - 11 }, .{ .x = xf - 4.5, .y = yf }, .{ .x = xf + 4.5, .y = yf }, col);
            rl.drawTriangle(.{ .x = xf, .y = yf + 11 }, .{ .x = xf + 4.5, .y = yf }, .{ .x = xf - 4.5, .y = yf }, lerpColor(col, rl.Color.black, 0.3));
            rl.drawTriangle(.{ .x = xf, .y = yf - 11 }, .{ .x = xf - 1.2, .y = yf }, .{ .x = xf + 1.6, .y = yf }, lite);
            rl.drawTriangle(.{ .x = xf - 8, .y = yf - 4 }, .{ .x = xf - 9.5, .y = yf + 2 }, .{ .x = xf - 6, .y = yf + 1 }, withAlpha(col, 190));
            rl.drawTriangle(.{ .x = xf + 8.5, .y = yf - 2 }, .{ .x = xf + 6.5, .y = yf + 3 }, .{ .x = xf + 10, .y = yf + 3.5 }, withAlpha(col, 160));
            rl.drawCircleV(.{ .x = xf - 2, .y = yf - 5 }, 1.1, rl.Color.white);
        },
        .lightning_nova => {
            // Nova ring with a jagged bolt struck through, sparks at the rim.
            rl.drawRing(.{ .x = xf, .y = yf }, 8, 9.5, 0, 360, 28, lerpColor(col, rl.Color.black, 0.15));
            rl.drawLineEx(.{ .x = xf + 2, .y = yf - 11 }, .{ .x = xf - 3, .y = yf - 2 }, 2.2, lite);
            rl.drawLineEx(.{ .x = xf - 3, .y = yf - 2 }, .{ .x = xf + 1, .y = yf - 2 }, 2.2, lite);
            rl.drawLineEx(.{ .x = xf + 1, .y = yf - 2 }, .{ .x = xf - 2, .y = yf + 11 }, 2.2, lite);
            rl.drawCircleV(.{ .x = xf + 7.5, .y = yf - 5 }, 1.0, withAlpha(lite, 200));
            rl.drawCircleV(.{ .x = xf - 7, .y = yf + 6 }, 1.2, withAlpha(lite, 170));
        },
        // The flask uses the belt's corked-flask icon, tinted its poison green.
        .toxic_flask => flaskIcon(cx - 7, cy - 9, col),
        .dodge => {
            // Roll: sweeping arc breaking into trailing dashes, arrowhead at the exit.
            rl.drawRing(.{ .x = xf, .y = yf }, 6.5, 8.5, -30, 200, 24, col);
            rl.drawRing(.{ .x = xf, .y = yf }, 6.5, 8.5, 215, 260, 10, withAlpha(col, 120));
            rl.drawRing(.{ .x = xf, .y = yf }, 6.5, 8.5, 275, 305, 8, withAlpha(col, 70));
            rl.drawTriangle(.{ .x = xf + 11, .y = yf - 6 }, .{ .x = xf + 3, .y = yf - 9.5 }, .{ .x = xf + 6, .y = yf - 2 }, col);
        },
        // Potions share the belt's corked-flask icon so the bar and the drop it came
        // from read alike (flaskIcon draws from a top-left origin — center it here).
        .health_potion, .mana_potion => flaskIcon(cx - 7, cy - 9, col),
    }
}

// Draw a skill emblem magnified by `k` about its center. The emblems are authored at a
// fixed ~24px extent, so a big well (the loadout slots, the pool chips) would otherwise
// leave them tiny and lost. Scaling through the GL matrix keeps the vector shapes crisp
// instead of upscaling a bitmap. k == 1 is the authored size (the live HUD bar).
fn skillEmblemScaled(cx: i32, cy: i32, s: playermod.Skill, col: rl.Color, k: f32) void {
    if (k == 1.0) {
        skillEmblem(cx, cy, s, col);
        return;
    }
    rl.gl.rlPushMatrix();
    defer rl.gl.rlPopMatrix();
    rl.gl.rlTranslatef(fi(cx), fi(cy), 0);
    rl.gl.rlScalef(k, k, 1);
    rl.gl.rlTranslatef(-fi(cx), -fi(cy), 0);
    skillEmblem(cx, cy, s, col);
}

// Is the skill usable right now? Combat skills gate on cooldown (and Firebolt on mana);
// potions on whether any are left in the belt.
fn skillReady(p: *const Player, s: playermod.Skill) bool {
    return switch (s) {
        .melee => p.atkCD <= 0,
        .firebolt => p.castCD <= 0 and p.Mana >= s.manaCost(),
        .dodge => p.rollCD <= 0,
        .health_potion => p.HealthPots > 0,
        .mana_potion => p.ManaPots > 0,
        // The extra skills gate on their own recharge plus (for spells) mana.
        .cleave, .throwing_knife, .ice_shard, .lightning_nova, .toxic_flask => p.auxReady(s) and p.Mana >= s.manaCost(),
    };
}

// Fraction of the skill's cooldown still remaining (1 = just used, 0 = ready), driving
// the darkening wipe over the icon. Divisors are the current recharge windows; potions
// have no cooldown (their "empty" state is shown by the count badge + grey emblem).
fn skillCooldownFrac(p: *const Player, s: playermod.Skill) f32 {
    return switch (s) {
        .melee => if (p.atkRate > 0) clampF(p.atkCD / p.atkRate, 0, 1) else 0,
        .firebolt => if (p.castRate > 0) clampF(p.castCD / p.castRate, 0, 1) else 0,
        .dodge => clampF(p.rollCD / p.rollCooldown(), 0, 1),
        .health_potion, .mana_potion => 0,
        .cleave, .throwing_knife, .ice_shard, .lightning_nova, .toxic_flask => p.auxFrac(s),
    };
}

// The ONE cooldown animation every skill uses (melee, firebolt, dodge alike): a dark
// radial "clock wipe" that unwinds clockwise from the top as the skill recharges
// (cd 1 → 0), with a faint spoke tracking the sweep line so it reads as motion. Scissored
// to the slot so the disc fills the square corners.
fn cooldownSweep(x: i32, y: i32, size: i32, cd: f32) void {
    if (cd <= 0) return;
    const cx = fi(x) + fi(size) / 2;
    const cy = fi(y) + fi(size) / 2;
    const c = rl.Vector2.init(cx, cy);
    const R = fi(size); // > the half-diagonal, so the scissor gives crisp square corners
    const end: f32 = -90.0 + 360.0 * cd;
    rl.beginScissorMode(x, y, size, size);
    rl.drawCircleSector(c, R, -90, end, 48, withAlpha(rgba(6, 6, 10, 255), 180));
    const er = mathx.radians(end);
    rl.drawLineEx(c, .{ .x = cx + mathx.cosf(er) * R, .y = cy + mathx.sinf(er) * R }, 1.5, withAlpha(rgba(220, 210, 190, 255), 95));
    rl.endScissorMode();
}

// Slot corner rounding, shared by the well fill, its brass liner, the no-mana veil, and
// the assignment-screen focus frame so a restyle moves them together.
const SLOT_ROUND: f32 = 0.18;
const SLOT_SEG: i32 = 6;

// One skill slot: dark well + brass liner, emblem, and a controller-button badge. When
// `p` is non-null (the live HUD bar) it also shows the cooldown wipe and an out-of-mana
// veil; null draws it statically. `slot` null omits the badge (the assignment screen
// draws its own larger glyph above the slot).
fn drawSkillSlot(x: i32, y: i32, size: i32, slot: ?usize, skill: ?playermod.Skill, p: ?*const Player, emScale: f32) void {
    const rect = rl.Rectangle{ .x = fi(x), .y = fi(y), .width = fi(size), .height = fi(size) };
    rl.drawRectangleRounded(rect, SLOT_ROUND, SLOT_SEG, rgba(12, 9, 8, 225));
    // Carved recess: shadow falls from the top lip, a faint catch on the bottom
    // one, candle warmth pooled in the well.
    rl.drawRectangleGradientV(x + 3, y + 2, size - 6, 10, withAlpha(rl.Color.black, 120), withAlpha(rl.Color.black, 0));
    rl.drawRectangle(x + 4, y + size - 3, size - 8, 1, withAlpha(theme.ironLight, 70));
    rl.drawCircleGradient(x + @divTrunc(size, 2), y + @divTrunc(size, 2), fi(size) * 0.5, withAlpha(rgba(255, 176, 90, 255), 16), withAlpha(rgba(255, 176, 90, 255), 0));
    if (skill) |s| {
        const ready = if (p) |pp| skillReady(pp, s) else true;
        const base = skillColor(s);
        const col = if (ready) base else lerpColor(base, rgba(40, 40, 44, 255), 0.55);
        skillEmblemScaled(x + @divTrunc(size, 2), y + @divTrunc(size, 2), s, col, emScale);
        if (p) |pp| {
            cooldownSweep(x, y, size, skillCooldownFrac(pp, s));
            const cost = s.manaCost();
            if (cost > 0 and pp.Mana < cost) {
                rl.drawRectangleRounded(rect, SLOT_ROUND, SLOT_SEG, withAlpha(theme.manaColor, 60)); // no-mana veil
            }
            // Consumable charge count, bottom-left (the button glyph owns bottom-right).
            const charges: ?i32 = switch (s) {
                .health_potion => pp.HealthPots,
                .mana_potion => pp.ManaPots,
                else => null,
            };
            if (charges) |c| {
                var cb: [8]u8 = undefined;
                const ct = std.fmt.bufPrintZ(&cb, "{d}", .{c}) catch "";
                // Seated count tag (bottom-left; the button badge owns bottom-right).
                rl.drawCircleV(.{ .x = fi(x + 10), .y = fi(y + size - 10) }, 8, withAlpha(theme.ink, 205));
                rl.drawCircleLines(x + 10, y + size - 10, 8, withAlpha(theme.trimColor, 110));
                glyphLabel(ct, x + 10, y + size - 10, 13, if (c > 0) theme.valueColor else rgba(150, 140, 130, 210));
            }
        }
    }
    rl.drawRectangleRoundedLinesEx(rect, SLOT_ROUND, SLOT_SEG, 1, withAlpha(theme.trimColor, if (skill != null) 175 else 90));
    if (slot) |i| {
        const gr = @max(@divTrunc(size, 5), 8);
        const pad = gr + 4;
        const bcx = x + size - pad;
        const bcy = y + size - pad;
        rl.drawCircleV(.{ .x = fi(bcx), .y = fi(bcy) }, fi(gr) + 3, rgba(10, 8, 7, 210)); // seat under the badge
        slotGlyph(i, bcx, bcy, gr);
    }
}

// Center a UI string within a box of width `w` starting at x.
fn textCenteredIn(s: [:0]const u8, x: i32, w: i32, y: i32, size: i32, col: rl.Color) void {
    text(s, x + @divTrunc(w - textW(s, size), 2), y, size, col);
}

// Ready-bloom: a slot flashes gilt the frame its cooldown completes. Module state
// (prev frac + bloom timer) — a completion is a transition, not a state, so the
// otherwise-stateless HUD has to remember one frame.
var slotPrevCd = [_]f32{0} ** playermod.SKILL_SLOTS;
var slotBloom = [_]f32{0} ** playermod.SKILL_SLOTS;

// Long-recharge skills only: a "ready again" flash on spammable basics would strobe.
fn bloomWorthy(s: playermod.Skill) bool {
    return switch (s) {
        .dodge, .cleave, .throwing_knife, .ice_shard, .lightning_nova, .toxic_flask => true,
        .melee, .firebolt, .health_potion, .mana_potion => false,
    };
}

// The always-on skill bar: the loadout's slots in one equal centered row seated in a
// PoE2-style tray, cooldowns live. Every slot is the same size — no "primary" slot —
// now that all skills are equally assignable to any button.
fn drawSkillBar(g: *const Game, cx: i32, y: i32) void {
    const size: i32 = 48;
    const gap: i32 = 8;
    const pad: i32 = 7; // tray inset around the row
    const total: i32 = playermod.SKILL_SLOTS * size + (playermod.SKILL_SLOTS - 1) * gap;
    const x0 = cx - @divTrunc(total, 2);
    // Riveted wood shelf under the slots: iron band, brass liner, corner studs.
    const tx = x0 - pad;
    const ty = y - pad;
    const tw = total + pad * 2;
    const th = size + pad * 2;
    // Grounding shadow: the shelf sits ON the screen, not floating over the world.
    rl.drawRectangleRounded(.{ .x = fi(tx + 4), .y = fi(ty + 5), .width = fi(tw), .height = fi(th) }, 0.15, 6, withAlpha(rl.Color.black, 60));
    rl.drawRectangleRounded(.{ .x = fi(tx + 2), .y = fi(ty + 2), .width = fi(tw), .height = fi(th) }, 0.15, 6, withAlpha(rl.Color.black, 85));
    woodPanel(tx, ty, tw, th, 215);
    rl.drawRectangleLinesEx(.{ .x = fi(tx), .y = fi(ty), .width = fi(tw), .height = fi(th) }, 2, withAlpha(theme.ironDark, 235));
    forgedRect(tx + 3, ty + 3, tw - 6, th - 6, withAlpha(theme.trimColor, flickA(130, tx)));
    for ([_][2]i32{ .{ tx + 6, ty + 6 }, .{ tx + tw - 6, ty + 6 }, .{ tx + 6, ty + th - 6 }, .{ tx + tw - 6, ty + th - 6 } }) |c| {
        rivet(c[0], c[1], 2.4);
    }
    var x = x0;
    var i: usize = 0;
    while (i < playermod.SKILL_SLOTS) : (i += 1) {
        if (g.p.bar.slots[i]) |s| {
            const cd = skillCooldownFrac(&g.p, s);
            if (bloomWorthy(s) and slotPrevCd[i] > 0.001 and cd <= 0.001) slotBloom[i] = 1;
            slotPrevCd[i] = cd;
        } else {
            slotPrevCd[i] = 0;
            slotBloom[i] = 0;
        }
        drawSkillSlot(x, y, size, i, g.p.bar.slots[i], &g.p, 1.5);
        if (slotBloom[i] > 0) {
            slotBloom[i] = @max(slotBloom[i] - rl.getFrameTime() * 3.0, 0);
            const k = slotBloom[i];
            const rect = rl.Rectangle{ .x = fi(x), .y = fi(y), .width = fi(size), .height = fi(size) };
            rl.drawRectangleRounded(rect, SLOT_ROUND, SLOT_SEG, withAlpha(theme.highlightColor, mathx.u8f(34 * k)));
            rl.drawRectangleRoundedLinesEx(rect, SLOT_ROUND, SLOT_SEG, 2.5, withAlpha(theme.highlightColor, mathx.u8f(215 * k)));
        }
        // A rivet seats in each gap between wells — the shelf is bolted, not printed.
        if (i + 1 < playermod.SKILL_SLOTS) rivet(x + size + @divTrunc(gap, 2), y + @divTrunc(size, 2), 1.8);
        x += size + gap;
    }
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
        const red = rgba(115, 8, 6, a);
        const clear = rgba(115, 8, 6, 0);
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

    drawResourceOrb(healthCX, orbY, orbR, p.HP, p.MaxHP, theme.healthColor, theme.healthSocket, t);
    drawResourceOrb(manaCX, orbY, orbR, p.Mana, p.MaxMana, theme.manaColor, theme.manaSocket, t);

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
        if (frac < 0.999) rl.drawRectangle(xpX + fw - 1, xpY, 2, 8, withAlpha(rgba(255, 245, 190, 255), 190));
    }
    barTicksFrame(xpX, xpY, xpW, 8, 10, 110);
    // Tenth pips under the channel — the measured-channel craft, readable at a glance.
    var q: i32 = 1;
    while (q < 10) : (q += 1) {
        diamond(xpX + @divTrunc(xpW * q, 10), xpY + 12, 1.6, withAlpha(theme.trimColor, 90));
    }
    // Brass jewels cap the channel where it meets each orb socket.
    finial(xpX - 8, xpY + 4, 5, 235);
    finial(xpX + xpW + 8, xpY + 4, 5, 235);
    // Level-up bloom: the channel flares gilt and its jewels swell for a breath.
    if (xpPrevLevel != p.Level) {
        if (xpPrevLevel >= 0 and p.Level > xpPrevLevel) xpBloom = 1;
        xpPrevLevel = p.Level;
    }
    if (xpBloom > 0) {
        xpBloom = @max(xpBloom - rl.getFrameTime() * 1.3, 0);
        const k = xpBloom;
        rl.drawRectangle(xpX - 2, xpY - 2, xpW + 4, 12, withAlpha(theme.highlightColor, mathx.u8f(110 * k)));
        finial(xpX - 8, xpY + 4, 5 + 3 * k, 255);
        finial(xpX + xpW + 8, xpY + 4, 5 + 3 * k, 255);
    }

    // No gold/level readout on the HUD (owner decree 2026-07-17): the sheet carries
    // level, pickups toast the gold. The bottom band is orbs + tray + XP only.

    // Reassignable skill bar: one equal PoE2-style tray of every action — combat skills
    // AND the two potions. Each slot's cooldown/charges ride the slot itself.
    drawSkillBar(g, @divTrunc(W, 2), H - 87);

    drawTopRight(g);
    drawEnemyPlate(g);

    // Transient status toast: a small hung plaque under the enemy plate zone —
    // forged liner and side finials, everything riding the fade alpha.
    if (g.toast.active()) {
        const a = mathx.u8f(clampF(g.toast.time / gamemod.TOAST_DUR * 255, 0, 255));
        const toastW = textW(g.toast.text(), 22);
        const tx = @divTrunc(W, 2) - @divTrunc(toastW, 2) - 18;
        const tw = toastW + 36;
        rl.drawRectangle(tx, 78, tw, 36, withAlpha(theme.ink, mathx.u8f(fi(a) * 0.6)));
        forgedRect(tx, 78, tw, 36, withAlpha(theme.trimColor, mathx.u8f(fi(a) * 0.5)));
        finial(tx, 96, 4, mathx.u8f(fi(a) * 0.85));
        finial(tx + tw, 96, 4, mathx.u8f(fi(a) * 0.85));
        centered(g.toast.text(), 84, 22, withAlpha(rgba(255, 245, 210, 255), a));
    }

    // Area-name banner: glowing title flanked by fading gold rules.
    if (g.banner.active()) {
        const a = clampF(g.banner.time, 0, 1);
        const a8 = mathx.u8f(a * 255);
        const by = @divTrunc(H, 3);
        const bw = textW(g.banner.text(), 56);
        ornateRules(@divTrunc(W, 2), by + 30, @divTrunc(bw, 2) + 24, 150, a8);
        glowCentered(g.banner.text(), by, 56, withAlpha(rgba(255, 225, 160, 255), a8), withAlpha(rgba(160, 70, 20, 255), @intFromFloat(fi(a8) * 0.35)));
    }
}

// Corked flask icon (bulb + neck + shine). The two potions are skill-bar slots now, so
// this is the emblem `skillEmblem` draws for `.health_potion`/`.mana_potion`/`.toxic_flask`.
fn flaskIcon(x: i32, y: i32, col: rl.Color) void {
    rl.drawRectangle(x + 4, y + 2, 6, 5, rgba(24, 20, 16, 255)); // neck
    rl.drawRectangle(x + 3, y, 8, 3, theme.corkColor); // cork
    rl.drawRectangle(x + 3, y + 2, 8, 1, lerpColor(theme.corkColor, rl.Color.black, 0.35)); // cork band
    rl.drawRectangleRounded(.{ .x = fi(x), .y = fi(y + 6), .width = 14, .height = 13 }, 0.7, 6, lerpColor(col, rl.Color.black, 0.3)); // glass
    rl.drawRectangleRounded(.{ .x = fi(x + 2), .y = fi(y + 9), .width = 10, .height = 8 }, 0.7, 6, col); // liquid, settled below the shoulder
    rl.drawRectangle(x + 2, y + 9, 10, 1, lerpColor(col, rl.Color.white, 0.35)); // meniscus
    rl.drawRectangle(x + 3, y + 10, 2, 4, withAlpha(rl.Color.white, 110)); // glass shine
    rl.drawCircleV(.{ .x = fi(x) + 10.5, .y = fi(y) + 12.5 }, 1.0, withAlpha(rl.Color.white, 90)); // bubble
}

// Top-right iron plaque: enemy count behind a skull pip, with the FPS / frame-time /
// object readout small and grey beneath it.
fn drawTopRight(g: *Game) void {
    const W = sw();
    var b1: [32]u8 = undefined;
    const en = std.fmt.bufPrintZ(&b1, "{d}", .{g.remainingMonsters()}) catch "";
    var b2: [64]u8 = undefined;
    const perf = std.fmt.bufPrintZ(&b2, "FPS {d}  {d:.1} ms  {d} obj", .{ rl.getFPS(), rl.getFrameTime() * 1000, g.objectCount() }) catch "";
    // Plaque width from worst-case templates, not the live strings — a plaque
    // nailed to the wall doesn't resize as the numbers tick.
    const w = @max(textW("888", 22) + 46, textW("FPS 888  88.8 ms  8888 obj", 12) + 24);
    const x = W - w - 10;
    rl.drawRectangle(x, 8, w, 50, withAlpha(theme.ink, 185));
    rl.drawRectangleLines(x, 8, w, 50, withAlpha(theme.ironDark, 230));
    forgedRect(x + 1, 9, w - 2, 48, withAlpha(theme.trimColor, 100));
    for ([_][2]i32{ .{ x + 6, 14 }, .{ x + w - 6, 14 }, .{ x + 6, 52 }, .{ x + w - 6, 52 } }) |c| {
        rivet(c[0], c[1], 2.2);
    }
    // Skull pip: cranium, jaw, hollow sockets.
    const px = x + 14;
    const bone = rgba(222, 208, 188, 255);
    rl.drawCircle(px + 6, 22, 6, bone);
    rl.drawRectangle(px + 3, 26, 7, 4, bone);
    rl.drawCircle(px + 4, 22, 2, rgba(26, 10, 10, 255));
    rl.drawCircle(px + 9, 22, 2, rgba(26, 10, 10, 255));
    text(en, px + 20, 12, 22, rgba(255, 205, 195, 245));
    text(perf, x + 12, 38, 12, rgba(150, 175, 150, 150));
    hangStrap(x + 8, 8);
    hangStrap(x + w - 8, 8);
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
    const cy = @divTrunc(sh(), 2);
    glowCentered("PAUSED", cy - 30, 60, rgba(242, 222, 182, 255), rgba(90, 60, 15, 100));
    ornamentDivider(@divTrunc(sw(), 2), cy + 56, 230, 220);
    const hints = [_]Hint{.{ .glyph = .menu, .label = "resume (or P)" }};
    hintRow(&hints, cy + 84, 18, sheetDim);
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
    // Masthead shimmer: a cream glint sweeps the letterforms on a slow shared
    // clock, with a long dark beat between passes — never a bar over the text.
    const shimPer: f32 = 5.6;
    const shim = @mod(t, shimPer) / shimPer;
    if (shim < 0.35) {
        const mw = textW("ZIG DIABLO", 76);
        const mx = @divTrunc(W, 2) - @divTrunc(mw, 2);
        const bandW: i32 = 90;
        const bx2 = mx - bandW + @as(i32, @intFromFloat(shim / 0.35 * fi(mw + bandW * 2)));
        rl.beginScissorMode(bx2, @divTrunc(H, 2) - 180, bandW, 95);
        drawStr("ZIG DIABLO", mx, @divTrunc(H, 2) - 180, 76, rgba(255, 236, 205, 200));
        rl.endScissorMode();
    }
    ornamentDivider(@divTrunc(W, 2), @divTrunc(H, 2) - 85, 340, 255);

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
            // Gold diamonds flank the chosen line, breathing.
            const flare = mathx.u8f(180 + 60 * sinf(t * 3));
            const gap = @divTrunc(w, 2) + 34;
            diamond(@divTrunc(W, 2) - gap - 8, y + 20, 5, withAlpha(theme.goldColor, flare));
            diamond(@divTrunc(W, 2) + gap + 8, y + 20, 5, withAlpha(theme.goldColor, flare));
            engravedCentered(label, y, size, selectedGold);
        } else {
            engravedCentered(label, y + 3, size, rgba(205, 188, 165, 215));
        }
        y += 56;
    }

    if (g.menuMode == .options) {
        centered("Alt+Enter toggles fullscreen windowed anywhere", y + 14, 15, rgba(170, 158, 140, 190));
    }
}

fn drawDeath(g: *Game) void {
    const cy = @divTrunc(sh(), 2);
    rl.drawRectangle(0, 0, sw(), sh(), rgba(14, 0, 0, 160));
    radialWash(rgba(80, 0, 0, 210), 1.05);
    emberField(g.elapsed, 14, rgba(200, 40, 30, 160), true);
    glowCentered("YOU HAVE DIED", cy - 80, 70, rgba(225, 45, 40, 255), rgba(70, 5, 5, 130));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "You reached {s} at level {d} with {d} kills.", .{ g.map.name.slice(), g.p.Level, g.kills }) catch "";
    centered(s, cy + 10, 22, rgba(230, 210, 200, 255));
    ornamentDivider(@divTrunc(sw(), 2), cy + 54, 240, 200);
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    const hints = [_]Hint{.{ .glyph = .{ .face = .a }, .label = "Start a new game" }};
    hintRow(&hints, cy + 86, 22, withAlpha(hintPulseGold, pulse));
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
    ornamentDivider(@divTrunc(sw(), 2), cy + 82, 240, 200);
    const pulse = mathx.u8f(200 + 55 * sinf(g.elapsed * 2.5));
    const hints = [_]Hint{.{ .glyph = .{ .face = .a }, .label = "Play again" }};
    hintRow(&hints, cy + 112, 22, withAlpha(hintPulseGold, pulse));
}
