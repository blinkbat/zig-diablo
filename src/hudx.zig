const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const playermod = @import("player.zig");

const rgba = mathx.rgba;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;
const Player = playermod.Player;

// HUD for the game (game.zig). Orbs / bars ported from hud.zig but driven directly
// by the Player struct + a few loop values, rather than the old GameState. 2D only —
// drawn after endMode3D, so it never touches the torch lighting.

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

    rl.drawRectangle(x, y, 12, 16, rgba(200, 40, 50, 255));
    rl.drawRectangleLines(x, y, 12, 16, rgba(20, 20, 20, 255));
    text(hpTxt, x + 16, y, 16, rl.Color.white);
    x += w1 + gap;

    rl.drawRectangle(x, y, 12, 16, rgba(50, 90, 230, 255));
    rl.drawRectangleLines(x, y, 12, 16, rgba(20, 20, 20, 255));
    text(mpTxt, x + 16, y, 16, rl.Color.white);
    x += w2 + gap;

    text(goldTxt, x, y, 16, rgba(255, 215, 80, 255));
}

// Edge vignette so the eye stays on the lit center.
fn vignette() void {
    const cx = @divTrunc(sw(), 2);
    const cy = @divTrunc(sh(), 2);
    const r = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.02;
    rl.drawCircleGradient(cx, cy, r, rgba(0, 0, 0, 0), rgba(0, 0, 0, 150));
}

pub fn draw(p: *const Player, areaName: []const u8, enemies: usize, bannerTime: f32, won: bool) void {
    const W = sw();
    const H = sh();

    vignette();

    // Red damage flash, keyed off the hero's hit flash timer (set by takeDamage).
    if (p.hitFlash > 0) {
        const a = mathx.u8f(clampF(p.hitFlash / 0.25 * 120, 0, 120));
        rl.drawRectangle(0, 0, W, H, rgba(180, 0, 0, a));
    }

    const orbR: i32 = 54;
    const orbY = H - orbR - 16;
    const xpW: i32 = 420;
    const xpX = @divTrunc(W, 2) - @divTrunc(xpW, 2);
    const xpY = H - 18;
    const healthCX = xpX - 24 - orbR;
    const manaCX = xpX + xpW + 24 + orbR;

    drawOrb(healthCX, orbY, orbR, p.HP / p.MaxHP, rgba(190, 30, 30, 255), rgba(60, 14, 14, 255));
    var b1: [64]u8 = undefined;
    const hp = std.fmt.bufPrintZ(&b1, "{d}/{d}", .{ @as(i32, @intFromFloat(p.HP)), @as(i32, @intFromFloat(p.MaxHP)) }) catch "";
    text(hp, healthCX - @divTrunc(rl.measureText(hp, 16), 2), orbY - 8, 16, rl.Color.white);

    drawOrb(manaCX, orbY, orbR, p.Mana / p.MaxMana, rgba(40, 70, 210, 255), rgba(16, 22, 60, 255));
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

    var b4: [32]u8 = undefined;
    const en = std.fmt.bufPrintZ(&b4, "enemies {d}", .{enemies}) catch "";
    text(en, W - rl.measureText(en, 18) - 16, 12, 18, rgba(230, 180, 180, 230));

    // Area-name banner, fading over its last second.
    if (bannerTime > 0) {
        var nb: [96]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&nb, "{s}", .{areaName}) catch "";
        const a = mathx.u8f(clampF(bannerTime, 0, 1) * 255);
        centered(nm, @divTrunc(H, 3), 48, withAlpha(rgba(255, 225, 160, 255), a));
    }

    if (won) centered("VICTORY - you cleared the catacombs!", @divTrunc(H, 2), 32, rgba(255, 215, 80, 255));
}
