const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const gamemod = @import("game.zig");
const playermod = @import("player.zig");
const theme = @import("theme.zig");

const Game = gamemod.Game;
const Player = playermod.Player;
const rgba = mathx.rgba;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;
const v3 = mathx.v3;

// HUD + world overlays + scene screens for the game (game.zig). 2D only — drawn after
// endMode3D, so it never touches the torch lighting.

// Height (px) of the bottom band the HUD occupies (orbs, belt, XP bar). The single
// source of truth for how tall the HUD is; game.zig reads it to ignore world clicks
// that land on the HUD, so the two can't drift apart.
pub const bottomBandHeight: i32 = 130;

fn sw() i32 {
    return rl.getScreenWidth();
}
fn sh() i32 {
    return rl.getScreenHeight();
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

// Top-level dispatcher: called once per frame after the 3D pass.
pub fn draw(g: *Game, cam: rl.Camera3D) void {
    switch (g.scene) {
        .menu => {
            vignette();
            drawMenu();
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

// Monster health bars + floating combat text, projected from world to screen.
fn drawWorldOverlays(g: *Game, cam: rl.Camera3D) void {
    const ms = g.liveMonsters();
    for (ms) |*m| {
        if (!m.alive() or !g.inVision(m.Pos)) continue;
        const hovered = m.id == g.hoverMonster; // hoverMonster is an id, so no stale-index risk
        const showBar = m.aggro or hovered or m.HP < m.MaxHP or m.boss;
        if (!showBar) continue;
        const head = v3(m.Pos.x, m.Height + 0.7, m.Pos.z);
        const sp = rl.getWorldToScreen(head, cam);
        if (!projValid(sp)) continue;
        const bw: f32 = if (m.boss) 90 else 46;
        const frac = clampF(m.HP / m.MaxHP, 0, 1);
        const x: i32 = @intFromFloat(sp.x - bw / 2);
        const y: i32 = @intFromFloat(sp.y);
        rl.drawRectangle(x - 1, y - 1, @as(i32, @intFromFloat(bw)) + 2, 7, rgba(0, 0, 0, 210));
        const fillCol = if (m.boss) rgba(230, 40, 110, 255) else rgba(200, 50, 40, 255);
        rl.drawRectangle(x, y, @intFromFloat(bw * frac), 5, fillCol);
        if (hovered or m.boss) {
            var nbuf: [64]u8 = undefined;
            const label = std.fmt.bufPrintZ(&nbuf, "{s}", .{m.Name}) catch "";
            const lw = rl.measureText(label, 14);
            text(label, @as(i32, @intFromFloat(sp.x)) - @divTrunc(lw, 2), y - 18, 14, rgba(255, 220, 200, 255));
        }
    }

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

// A liquid-filled globe: dark socket, colored fill scissored to `frac`, glossy
// highlight, metal rim.
fn drawOrb(cx: i32, cy: i32, radius: i32, frac_in: f32, full: rl.Color, empty: rl.Color) void {
    const frac = clampF(frac_in, 0, 1);
    rl.drawCircle(cx, cy, @as(f32, @floatFromInt(radius)) + 4, rgba(10, 8, 6, 230));
    rl.drawCircle(cx, cy, @floatFromInt(radius), empty);
    const fillH: i32 = @intFromFloat(@as(f32, @floatFromInt(radius * 2)) * frac);
    if (fillH > 0) {
        const top = cy + radius - fillH;
        rl.beginScissorMode(cx - radius, top, radius * 2, fillH);
        rl.drawCircle(cx, cy, @floatFromInt(radius), full);
        rl.drawCircle(cx - @divTrunc(radius, 3), top + @divTrunc(radius, 4), @as(f32, @floatFromInt(radius)) / 3.5, withAlpha(rl.Color.white, 60));
        rl.endScissorMode();
    }
    rl.drawRing(rl.Vector2.init(@floatFromInt(cx), @floatFromInt(cy)), @floatFromInt(radius), @as(f32, @floatFromInt(radius)) + 4, 0, 360, 48, rgba(35, 28, 20, 255));
}

fn drawHUD(g: *Game) void {
    const p = &g.p;
    const W = sw();
    const H = sh();

    // Red damage flash.
    if (g.damageFlash > 0) {
        const a = mathx.u8f(clampF(g.damageFlash / gamemod.DAMAGE_FLASH_DUR * 120, 0, 120));
        rl.drawRectangle(0, 0, W, H, rgba(180, 0, 0, a));
    }

    const orbR: i32 = 54;
    const orbY = H - orbR - 16;
    const xpW: i32 = 420;
    const xpX = @divTrunc(W, 2) - @divTrunc(xpW, 2);
    const xpY = H - 18;
    const healthCX = xpX - 24 - orbR;
    const manaCX = xpX + xpW + 24 + orbR;

    drawOrb(healthCX, orbY, orbR, p.HP / p.MaxHP, theme.healthColor, theme.healthSocket);
    var b1: [64]u8 = undefined;
    const hp = std.fmt.bufPrintZ(&b1, "{d}/{d}", .{ @as(i32, @intFromFloat(p.HP)), @as(i32, @intFromFloat(p.MaxHP)) }) catch "";
    text(hp, healthCX - @divTrunc(rl.measureText(hp, 16), 2), orbY - 8, 16, rl.Color.white);

    drawOrb(manaCX, orbY, orbR, p.Mana / p.MaxMana, theme.manaColor, theme.manaSocket);
    var b2: [64]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&b2, "{d}/{d}", .{ @as(i32, @intFromFloat(p.Mana)), @as(i32, @intFromFloat(p.MaxMana)) }) catch "";
    text(mp, manaCX - @divTrunc(rl.measureText(mp, 16), 2), orbY - 8, 16, rl.Color.white);

    // XP bar (guard against XPNext == 0).
    const frac = if (p.XPNext > 0) @as(f32, @floatFromInt(p.XP)) / @as(f32, @floatFromInt(p.XPNext)) else 0;
    rl.drawRectangle(xpX, xpY, xpW, 10, rgba(0, 0, 0, 200));
    rl.drawRectangle(xpX, xpY, @as(i32, @intFromFloat(@as(f32, @floatFromInt(xpW)) * clampF(frac, 0, 1))), 10, rgba(210, 180, 60, 255));
    rl.drawRectangleLines(xpX, xpY, xpW, 10, rgba(40, 32, 18, 255));

    var b3: [32]u8 = undefined;
    const lvl = std.fmt.bufPrintZ(&b3, "Level {d}", .{p.Level}) catch "";
    text(lvl, @divTrunc(W, 2) - @divTrunc(rl.measureText(lvl, 20), 2), H - 44, 20, rgba(255, 235, 170, 255));

    drawBelt(p, @divTrunc(W, 2), H - 70);

    // Dodge-ready pip: bright when ready, dim while recharging.
    const pipCol = if (p.rollCD > 0) rgba(90, 90, 100, 200) else rgba(150, 200, 255, 230);
    rl.drawCircle(@divTrunc(W, 2), H - 84, 4, pipCol);

    drawPerf(g);

    var b4: [32]u8 = undefined;
    const en = std.fmt.bufPrintZ(&b4, "enemies {d}", .{g.remainingMonsters()}) catch "";
    text(en, W - rl.measureText(en, 18) - 16, 32, 18, rgba(230, 180, 180, 230));

    // Transient status toast (top-center).
    if (g.toast.active()) {
        const a = mathx.u8f(clampF(g.toast.time / gamemod.TOAST_DUR * 255, 0, 255));
        centered(g.toast.text(), 14, 22, withAlpha(rgba(255, 245, 210, 255), a));
    }

    // Area-name banner (big, fades on entry).
    if (g.banner.active()) {
        const a = mathx.u8f(clampF(g.banner.time, 0, 1) * 255);
        centered(g.banner.text(), @divTrunc(H, 3), 56, withAlpha(rgba(255, 225, 160, 255), a));
    }
}

// A centered potion/gold belt.
fn drawBelt(p: *const Player, cx: i32, y: i32) void {
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [24]u8 = undefined;
    const hpTxt = std.fmt.bufPrintZ(&b1, "x{d}", .{p.HealthPots}) catch "";
    const mpTxt = std.fmt.bufPrintZ(&b2, "x{d}", .{p.ManaPots}) catch "";
    const goldTxt = std.fmt.bufPrintZ(&b3, "{d} g", .{p.Gold}) catch "";

    const w1 = 16 + rl.measureText(hpTxt, 16);
    const w2 = 16 + rl.measureText(mpTxt, 16);
    const gap: i32 = 20;
    const total = w1 + gap + w2 + gap + rl.measureText(goldTxt, 16);
    var x = cx - @divTrunc(total, 2);

    rl.drawRectangle(x, y, 12, 16, theme.healthColor);
    rl.drawRectangleLines(x, y, 12, 16, rgba(20, 20, 20, 255));
    text(hpTxt, x + 16, y, 16, rl.Color.white);
    x += w1 + gap;

    rl.drawRectangle(x, y, 12, 16, theme.manaColor);
    rl.drawRectangleLines(x, y, 12, 16, rgba(20, 20, 20, 255));
    text(mpTxt, x + 16, y, 16, rl.Color.white);
    x += w2 + gap;

    text(goldTxt, x, y, 16, theme.goldColor);
}

// Small FPS / frame-time / object-count readout, top-right.
fn drawPerf(g: *Game) void {
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buf, "FPS {d}   {d:.1} ms   {d} obj", .{ rl.getFPS(), rl.getFrameTime() * 1000, g.objectCount() }) catch "";
    text(txt, sw() - rl.measureText(txt, 14) - 10, 8, 14, rgba(150, 200, 150, 220));
}

// Edge vignette so the eye stays on the lit center.
fn vignette() void {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    const r = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.02;
    rl.drawCircleGradient(cx, cy, r, rgba(0, 0, 0, 0), rgba(0, 0, 0, 150));
}

fn drawPauseOverlay() void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 150));
    centered("PAUSED", @divTrunc(sh(), 2) - 30, 60, rl.Color.white);
    centered("Press P to resume", @divTrunc(sh(), 2) + 40, 24, rgba(220, 220, 220, 255));
}

fn drawMenu() void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 150));
    centered("GO DIABLO", @divTrunc(sh(), 2) - 150, 90, rgba(200, 40, 40, 255));
    centered("A Diablo II-style action RPG", @divTrunc(sh(), 2) - 50, 26, rgba(220, 200, 180, 255));
    centered("Press ENTER to descend", @divTrunc(sh(), 2) + 30, 32, rgba(255, 230, 160, 255));

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
    var y = @divTrunc(sh(), 2) + 90;
    for (lines) |ln| {
        centered(ln, y, 18, rgba(200, 200, 200, 230));
        y += 26;
    }
}

fn drawDeath(g: *Game) void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(40, 0, 0, 180));
    centered("YOU HAVE DIED", @divTrunc(sh(), 2) - 80, 70, rgba(220, 40, 40, 255));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "You reached {s} at level {d} with {d} kills.", .{ g.w.Name, g.p.Level, g.kills }) catch "";
    centered(s, @divTrunc(sh(), 2) + 10, 22, rgba(230, 210, 200, 255));
    centered("Press R to start a new game", @divTrunc(sh(), 2) + 60, 26, rgba(255, 230, 160, 255));
}

fn drawVictory(g: *Game) void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 170));
    centered("VICTORY!", @divTrunc(sh(), 2) - 90, 80, rgba(255, 215, 80, 255));
    centered("You have cleared the catacombs and triumphed over the darkness.", @divTrunc(sh(), 2) + 10, 22, rgba(230, 220, 200, 255));
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "Final level {d}  -  {d} gold  -  {d} kills", .{ g.p.Level, g.p.Gold, g.kills }) catch "";
    centered(s, @divTrunc(sh(), 2) + 44, 22, rgba(255, 235, 170, 255));
    centered("Press ENTER to play again", @divTrunc(sh(), 2) + 96, 26, rgba(255, 230, 160, 255));
}
