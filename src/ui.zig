const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");

const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const withAlpha = mathx.withAlpha;

// UI — a tiny immediate-mode widget kit for the editor (raylib, IM Fell type via
// hudx). Each widget hit-tests AND draws in one call; the caller applies results
// on the spot. `Ctx.anyHot` accumulates "the pointer is over some widget this
// frame" — the editor stores it and gates world clicks on it NEXT frame (the
// one-frame lag is imperceptible and avoids a layout/interaction split).

pub const Ctx = struct {
    mouse: rl.Vector2,
    pressed: bool, // LMB went down this frame
    down: bool, // LMB held
    anyHot: bool = false, // pointer over any widget (accumulated)

    pub fn begin() Ctx {
        return .{
            .mouse = rl.getMousePosition(),
            .pressed = rl.isMouseButtonPressed(.left),
            .down = rl.isMouseButtonDown(.left),
        };
    }

    fn hot(ctx: *Ctx, r: rl.Rectangle) bool {
        const h = rl.checkCollisionPointRec(ctx.mouse, r);
        if (h) ctx.anyHot = true;
        return h;
    }
};

pub fn rect(x: i32, y: i32, w: i32, h: i32) rl.Rectangle {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
}

// Iron panel with a brass liner; optional small-caps title tab.
pub fn panel(r: rl.Rectangle, title: ?[:0]const u8) void {
    rl.drawRectangleRounded(r, 0.08, 6, rgba(10, 8, 7, 215));
    rl.drawRectangleRoundedLinesEx(r, 0.08, 6, 1, withAlpha(theme.trimColor, 120));
    if (title) |t| {
        hudx.text(t, @intFromFloat(r.x + 10), @intFromFloat(r.y + 6), 16, withAlpha(theme.trimColor, 230));
    }
}

// A clickable text button. `active` renders it latched (brass fill) for tool
// palettes and tabs. Returns true on click.
pub fn button(ctx: *Ctx, r: rl.Rectangle, label: [:0]const u8, size: i32, active: bool) bool {
    const h = ctx.hot(r);
    const base = if (active) rgba(96, 74, 40, 235) else rgba(24, 19, 15, 225);
    const face = if (h and !active) rgba(38, 30, 23, 235) else base;
    rl.drawRectangleRounded(r, 0.25, 4, face);
    rl.drawRectangleRoundedLinesEx(r, 0.25, 4, 1, withAlpha(theme.trimColor, if (active) 220 else if (h) 170 else 90));
    const tw = hudx.textW(label, size);
    const tx: i32 = @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2);
    const ty: i32 = @intFromFloat(r.y + (r.height - @as(f32, @floatFromInt(size))) / 2 - 2);
    hudx.text(label, tx, ty, size, if (active) rgba(255, 235, 190, 255) else rgba(225, 212, 190, 240));
    return h and ctx.pressed;
}

// A compact auto-width chip (variant pickers). Returns clicked; writes the width
// it used so callers can flow chips in a row.
pub fn chip(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, active: bool, usedW: *i32) bool {
    const w = hudx.textW(label, 15) + 16;
    usedW.* = w + 6;
    return button(ctx, rect(x, y, w, 24), label, 15, active);
}

// [-] value [+] stepper for a float. Returns true when the value changed.
pub fn stepperF(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, v: *f32, step: f32, min: f32, max: f32) bool {
    hudx.text(label, x, y + 3, 15, rgba(200, 190, 172, 230));
    const bx = x + 92;
    var changed = false;
    if (button(ctx, rect(bx, y, 22, 22), "-", 16, false)) {
        v.* = mathx.clampF(v.* - step, min, max);
        changed = true;
    }
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d:.1}", .{v.*}) catch "";
    hudx.text(s, bx + 30 + @divTrunc(34 - hudx.textW(s, 16), 2), y + 3, 16, rgba(255, 240, 205, 255));
    if (button(ctx, rect(bx + 96, y, 22, 22), "+", 16, false)) {
        v.* = mathx.clampF(v.* + step, min, max);
        changed = true;
    }
    return changed;
}

// [-] value [+] stepper for an integer.
pub fn stepperI(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, v: *i32, min: i32, max: i32) bool {
    hudx.text(label, x, y + 3, 15, rgba(200, 190, 172, 230));
    const bx = x + 92;
    var changed = false;
    if (button(ctx, rect(bx, y, 22, 22), "-", 16, false)) {
        v.* = mathx.clampI(v.* - 1, min, max);
        changed = true;
    }
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}", .{v.*}) catch "";
    hudx.text(s, bx + 30 + @divTrunc(34 - hudx.textW(s, 16), 2), y + 3, 16, rgba(255, 240, 205, 255));
    if (button(ctx, rect(bx + 96, y, 22, 22), "+", 16, false)) {
        v.* = mathx.clampI(v.* + 1, min, max);
        changed = true;
    }
    return changed;
}

// A color swatch (palette presets). Returns clicked.
pub fn swatch(ctx: *Ctx, x: i32, y: i32, w: i32, h: i32, fill: rl.Color, edge: rl.Color, active: bool) bool {
    const r = rect(x, y, w, h);
    const hov = ctx.hot(r);
    rl.drawRectangleRounded(r, 0.25, 4, fill);
    rl.drawRectangleRoundedLinesEx(r, 0.25, 4, if (active) 2 else 1, if (active) rgba(255, 235, 190, 255) else if (hov) withAlpha(theme.trimColor, 220) else edge);
    return hov and ctx.pressed;
}

// Single-line text field. The caller owns focus; while focused this consumes
// typed characters and backspace. Draws a breathing caret.
pub fn textField(ctx: *Ctx, r: rl.Rectangle, buf: []u8, len: *usize, focused: bool, t: f32) void {
    _ = ctx.hot(r);
    rl.drawRectangleRounded(r, 0.2, 4, rgba(16, 13, 11, 240));
    rl.drawRectangleRoundedLinesEx(r, 0.2, 4, 1, withAlpha(theme.trimColor, if (focused) 220 else 110));
    if (focused) {
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127 and len.* < buf.len - 1) {
                buf[len.*] = @intCast(ch);
                len.* += 1;
            }
        }
        if ((rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) and len.* > 0) len.* -= 1;
    }
    buf[len.*] = 0;
    const s: [:0]const u8 = buf[0..len.* :0];
    hudx.text(s, @intFromFloat(r.x + 8), @intFromFloat(r.y + 4), 18, rgba(255, 240, 205, 255));
    if (focused and @mod(t, 1.0) < 0.55) {
        const cx: i32 = @as(i32, @intFromFloat(r.x)) + 10 + hudx.textW(s, 18);
        rl.drawRectangle(cx, @intFromFloat(r.y + 5), 2, 18, rgba(255, 235, 190, 220));
    }
}

// Modal scaffold: dim the screen, center a panel, return its top-left in PIXEL
// ints (every caller lays out in ints — returning a float Rectangle forced an
// @intFromFloat ceremony at every field). The backdrop eats the pointer (sets
// anyHot) so nothing behind it can be clicked.
pub const ModalBox = struct { x: i32, y: i32 };

pub fn beginModal(ctx: *Ctx, w: i32, h: i32, title: [:0]const u8) ModalBox {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.drawRectangle(0, 0, sw, sh, rgba(0, 0, 0, 140));
    ctx.anyHot = true; // a modal owns the pointer wholesale
    const x = @divTrunc(sw - w, 2);
    const y = @divTrunc(sh - h, 2);
    panel(rect(x, y, w, h), null);
    hudx.text(title, x + @divTrunc(w - hudx.textW(title, 20), 2), y + 12, 20, rgba(255, 230, 190, 255));
    return .{ .x = x, .y = y };
}
