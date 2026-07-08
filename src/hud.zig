const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");
const fow = @import("fow.zig");

const GameState = state.GameState;
const v3 = mathx.v3;
const rgba = mathx.rgba;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;

fn sw() i32 {
    return rl.getScreenWidth();
}
fn sh() i32 {
    return rl.getScreenHeight();
}

fn drawCenteredText(s: [:0]const u8, cy: i32, size: i32, col: rl.Color) void {
    const w = rl.measureText(s, size);
    rl.drawText(s, @divTrunc(sw(), 2) - @divTrunc(w, 2), cy, size, col);
}

// drawTextShadow draws text with a 2px drop shadow for legibility over 3D.
fn drawTextShadow(s: [:0]const u8, x: i32, y: i32, size: i32, col: rl.Color) void {
    rl.drawText(s, x + 2, y + 2, size, rgba(0, 0, 0, 200));
    rl.drawText(s, x, y, size, col);
}

// drawWorldOverlays draws monster health bars and floating combat text by
// projecting world positions to the screen. Must run after endMode3D.
pub fn drawWorldOverlays(g: *GameState, cam: rl.Camera3D) void {
    for (g.monsters.items, 0..) |*m, i| {
        if (!m.alive() or !fow.inVision(g, m.Pos)) continue;
        const idx: i32 = @intCast(i);
        const showBar = m.aggro or idx == g.hoverMonster or m.HP < m.MaxHP or m.boss;
        if (!showBar) continue;
        const head = v3(m.Pos.x, m.Height + 0.7, m.Pos.z);
        const sp = rl.getWorldToScreen(head, cam);
        if (!std.math.isFinite(sp.x) or !std.math.isFinite(sp.y)) continue; // guard near-plane projections
        var bw: f32 = 46;
        if (m.boss) bw = 90;
        const frac = clampF(m.HP / m.MaxHP, 0, 1);
        const x: i32 = @intFromFloat(sp.x - bw / 2);
        const y: i32 = @intFromFloat(sp.y);
        rl.drawRectangle(x - 1, y - 1, @as(i32, @intFromFloat(bw)) + 2, 7, rgba(0, 0, 0, 210));
        var fillCol = rgba(200, 50, 40, 255);
        if (m.boss) fillCol = rgba(230, 40, 110, 255);
        rl.drawRectangle(x, y, @intFromFloat(bw * frac), 5, fillCol);
        if (idx == g.hoverMonster or m.boss) {
            var nbuf: [64]u8 = undefined;
            const label = std.fmt.bufPrintZ(&nbuf, "{s}", .{m.Name}) catch "";
            const lw = rl.measureText(label, 14);
            drawTextShadow(label, @as(i32, @intFromFloat(sp.x)) - @divTrunc(lw, 2), y - 18, 14, rgba(255, 220, 200, 255));
        }
    }

    // Floating combat text (hidden when its source sits in fog of war).
    for (g.popups.items) |*pp| {
        if (!fow.inVision(g, pp.Pos)) continue;
        const sp = rl.getWorldToScreen(pp.Pos, cam);
        if (!std.math.isFinite(sp.x) or !std.math.isFinite(sp.y)) continue; // guard near-plane projections
        const a = mathx.u8f(clampF(pp.Life / pp.maxLife * 255, 0, 255));
        const col = withAlpha(pp.Color, a);
        var tbuf: [40]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&tbuf, "{s}", .{pp.text()}) catch "";
        const w = rl.measureText(txt, 20);
        rl.drawText(txt, @as(i32, @intFromFloat(sp.x)) - @divTrunc(w, 2) + 1, @as(i32, @intFromFloat(sp.y)) + 1, 20, rgba(0, 0, 0, a));
        rl.drawText(txt, @as(i32, @intFromFloat(sp.x)) - @divTrunc(w, 2), @as(i32, @intFromFloat(sp.y)), 20, col);
    }
}

fn drawOrb(cx: i32, cy: i32, radius: i32, frac_in: f32, full: rl.Color, empty: rl.Color) void {
    const frac = clampF(frac_in, 0, 1);
    rl.drawCircle(cx, cy, @as(f32, @floatFromInt(radius)) + 4, rgba(10, 8, 6, 230));
    rl.drawCircle(cx, cy, @floatFromInt(radius), empty);
    const fillH: i32 = @intFromFloat(@as(f32, @floatFromInt(radius * 2)) * frac);
    if (fillH > 0) {
        const top = cy + radius - fillH;
        rl.beginScissorMode(cx - radius, top, radius * 2, fillH);
        rl.drawCircle(cx, cy, @floatFromInt(radius), full);
        // Glossy highlight near the top of the liquid.
        rl.drawCircle(cx - @divTrunc(radius, 3), top + @divTrunc(radius, 4), @as(f32, @floatFromInt(radius)) / 3.5, withAlpha(rl.Color.white, 60));
        rl.endScissorMode();
    }
    rl.drawRing(rl.Vector2.init(@floatFromInt(cx), @floatFromInt(cy)), @floatFromInt(radius), @as(f32, @floatFromInt(radius)) + 4, 0, 360, 48, rgba(35, 28, 20, 255));
}

pub fn drawHUD(g: *GameState) void {
    const p = &g.player;
    const W = sw();
    const H = sh();

    // Damage vignette.
    if (g.damageFlash > 0) {
        const a = mathx.u8f(clampF(g.damageFlash / state.damageFlashDur * 120, 0, 120));
        rl.drawRectangle(0, 0, W, H, rgba(180, 0, 0, a));
    }

    const orbR: i32 = 56;
    const orbY = H - orbR - 16;
    const xpW: i32 = 420;
    const xpX = @divTrunc(W, 2) - @divTrunc(xpW, 2);
    const xpY = H - 18;
    const healthCX = xpX - 24 - orbR;
    const manaCX = xpX + xpW + 24 + orbR;

    drawOrb(healthCX, orbY, orbR, p.HP / p.MaxHP, rgba(190, 30, 30, 255), rgba(60, 14, 14, 255));
    var buf: [64]u8 = undefined;
    const hp = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ @as(i32, @intFromFloat(p.HP)), @as(i32, @intFromFloat(p.MaxHP)) }) catch "";
    drawTextShadow(hp, healthCX - @divTrunc(rl.measureText(hp, 16), 2), orbY - 8, 16, rl.Color.white);

    drawOrb(manaCX, orbY, orbR, p.Mana / p.MaxMana, rgba(40, 70, 210, 255), rgba(16, 22, 60, 255));
    var buf2: [64]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&buf2, "{d}/{d}", .{ @as(i32, @intFromFloat(p.Mana)), @as(i32, @intFromFloat(p.MaxMana)) }) catch "";
    drawTextShadow(mp, manaCX - @divTrunc(rl.measureText(mp, 16), 2), orbY - 8, 16, rl.Color.white);

    // Narrow XP bar, centered.
    const frac = @as(f32, @floatFromInt(p.XP)) / @as(f32, @floatFromInt(p.XPNext));
    rl.drawRectangle(xpX, xpY, xpW, 10, rgba(0, 0, 0, 200));
    rl.drawRectangle(xpX, xpY, @as(i32, @intFromFloat(@as(f32, @floatFromInt(xpW)) * clampF(frac, 0, 1))), 10, rgba(210, 180, 60, 255));
    rl.drawRectangleLines(xpX, xpY, xpW, 10, rgba(40, 32, 18, 255));

    // Level (centered above the bar).
    var buf3: [32]u8 = undefined;
    const lvl = std.fmt.bufPrintZ(&buf3, "Level {d}", .{p.Level}) catch "";
    drawTextShadow(lvl, @divTrunc(W, 2) - @divTrunc(rl.measureText(lvl, 20), 2), H - 44, 20, rgba(255, 235, 170, 255));

    // Potion belt + gold.
    drawBelt(g, @divTrunc(W, 2), H - 70);

    // Dodge-ready pip: bright when ready, dim while recharging.
    var pipCol = rgba(150, 200, 255, 230);
    if (p.rollCD > 0) pipCol = rgba(90, 90, 100, 200);
    rl.drawCircle(@divTrunc(W, 2), H - 84, 4, pipCol);

    drawPerf(g);

    // Transient status toast (top-center).
    if (g.toastTime > 0 and g.toast_len > 0) {
        const a = mathx.u8f(clampF(g.toastTime / state.toastDur * 255, 0, 255));
        drawCenteredText(g.toastText(), 14, 22, withAlpha(rgba(255, 245, 210, 255), a));
    }

    // Area banner (big, fades on entry).
    if (g.bannerTime > 0 and g.banner_len > 0) {
        const a = mathx.u8f(clampF(g.bannerTime, 0, 1) * 255);
        drawCenteredText(g.bannerText(), @divTrunc(H, 3), 56, withAlpha(rgba(255, 225, 160, 255), a));
    }
}

// drawBelt renders a small centered potion/gold row with no hotkey labels.
fn drawBelt(g: *GameState, cx: i32, y: i32) void {
    const p = &g.player;
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
    drawTextShadow(hpTxt, x + 16, y, 16, rl.Color.white);
    x += w1 + gap;

    rl.drawRectangle(x, y, 12, 16, rgba(50, 90, 230, 255));
    rl.drawRectangleLines(x, y, 12, 16, rgba(20, 20, 20, 255));
    drawTextShadow(mpTxt, x + 16, y, 16, rl.Color.white);
    x += w2 + gap;

    drawTextShadow(goldTxt, x, y, 16, rgba(255, 215, 80, 255));
}

// drawPerf shows a small FPS / frame-time / object-count readout, top-right.
fn drawPerf(g: *GameState) void {
    const ents = g.monsters.items.len + g.projectiles.items.len + g.loot.items.len;
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buf, "FPS {d}   {d:.1} ms   {d} obj", .{ rl.getFPS(), rl.getFrameTime() * 1000, ents }) catch "";
    drawTextShadow(txt, sw() - rl.measureText(txt, 14) - 10, 8, 14, rgba(150, 200, 150, 220));
}

// drawVignette darkens the screen edges so the eye stays on the lit center.
pub fn drawVignette(g: *GameState) void {
    _ = g;
    const W = sw();
    const H = sh();
    const cx = @divTrunc(W, 2);
    const cy = @divTrunc(H, 2);
    const radius = @sqrt(@as(f32, @floatFromInt(cx * cx + cy * cy))) * 1.02;
    rl.drawCircleGradient(cx, cy, radius, rgba(0, 0, 0, 0), rgba(0, 0, 0, 190));
}

pub fn drawPauseOverlay(g: *GameState) void {
    _ = g;
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 150));
    drawCenteredText("PAUSED", @divTrunc(sh(), 2) - 30, 60, rl.Color.white);
    drawCenteredText("Press P to resume", @divTrunc(sh(), 2) + 40, 24, rgba(220, 220, 220, 255));
}

pub fn drawMenu(g: *GameState) void {
    _ = g;
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 150));
    drawCenteredText("GO DIABLO", @divTrunc(sh(), 2) - 150, 90, rgba(200, 40, 40, 255));
    drawCenteredText("A Diablo II-style action RPG", @divTrunc(sh(), 2) - 50, 26, rgba(220, 200, 180, 255));
    drawCenteredText("Press ENTER to descend", @divTrunc(sh(), 2) + 30, 32, rgba(255, 230, 160, 255));

    const lines = [_][:0]const u8{
        "Left mouse  -  move, or attack the monster under the cursor",
        "Right mouse -  cast Firebolt toward the cursor (uses mana)",
        "Spacebar    -  dodge roll (brief invulnerability) - your lifeline",
        "1 / 2       -  drink Health / Mana potion",
        "Mouse wheel -  zoom    |    P - pause    |    Esc - quit",
        "",
        "This world is slow, methodical, and deadly. Blows are heavy and",
        "telegraphed in red - read them and roll clear. You cannot facetank.",
        "Clear every monster to open the portal; survive five areas to win.",
    };
    var y = @divTrunc(sh(), 2) + 90;
    for (lines) |ln| {
        drawCenteredText(ln, y, 18, rgba(200, 200, 200, 230));
        y += 26;
    }
}

pub fn drawDeath(g: *GameState) void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(40, 0, 0, 180));
    drawCenteredText("YOU HAVE DIED", @divTrunc(sh(), 2) - 80, 70, rgba(220, 40, 40, 255));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "You reached {s} at level {d} with {d} kills.", .{ g.world.Name, g.player.Level, g.kills }) catch "";
    drawCenteredText(s, @divTrunc(sh(), 2) + 10, 22, rgba(230, 210, 200, 255));
    drawCenteredText("Press R to start a new game", @divTrunc(sh(), 2) + 60, 26, rgba(255, 230, 160, 255));
}

pub fn drawVictory(g: *GameState) void {
    rl.drawRectangle(0, 0, sw(), sh(), rgba(0, 0, 0, 170));
    drawCenteredText("VICTORY!", @divTrunc(sh(), 2) - 90, 80, rgba(255, 215, 80, 255));
    drawCenteredText("You have cleared the catacombs and triumphed over the darkness.", @divTrunc(sh(), 2) + 10, 22, rgba(230, 220, 200, 255));
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "Final level {d}  -  {d} gold  -  {d} kills", .{ g.player.Level, g.player.Gold, g.kills }) catch "";
    drawCenteredText(s, @divTrunc(sh(), 2) + 44, 22, rgba(255, 235, 170, 255));
    drawCenteredText("Press ENTER to play again", @divTrunc(sh(), 2) + 96, 26, rgba(255, 230, 160, 255));
}
