const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");

const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const withAlpha = mathx.withAlpha;

// UI — tiny immediate-mode widget kit for the editor. Each widget hit-tests AND
// draws in one call. `Ctx.anyHot` accumulates "pointer over some widget this
// frame"; the editor gates world clicks on it NEXT frame (1-frame lag is
// imperceptible and avoids a layout/interaction split).

// Shared cap for short UI message buffers (tips, status toasts, confirm prompts).
pub const MSG_CAP = 96;

pub const Ctx = struct {
    mouse: rl.Vector2,
    pressed: bool, // LMB went down this frame
    down: bool, // LMB held
    anyHot: bool = false, // pointer over any widget (accumulated)

    // Deferred tooltip: last hover this frame wins, drawn on top by drawTip. Copied
    // into a buffer so formatted tips can use caller stack storage.
    tipBuf: [MSG_CAP]u8 = undefined,
    tipLen: usize = 0,

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

    pub fn setTip(ctx: *Ctx, text: []const u8) void {
        const n = @min(text.len, ctx.tipBuf.len - 1);
        @memcpy(ctx.tipBuf[0..n], text[0..n]);
        ctx.tipLen = n;
    }
};

// Attach a tooltip to any rectangle.
pub fn tipFor(ctx: *Ctx, r: rl.Rectangle, text: [:0]const u8) void {
    if (rl.checkCollisionPointRec(ctx.mouse, r)) ctx.setTip(text);
}

// A button that explains itself on hover.
pub fn buttonTip(ctx: *Ctx, r: rl.Rectangle, label: [:0]const u8, size: i32, active: bool, tp: [:0]const u8) bool {
    if (rl.checkCollisionPointRec(ctx.mouse, r)) ctx.setTip(tp);
    return button(ctx, r, label, size, active);
}

// Draw the pending tooltip at the cursor, clamped on-screen. Call LAST.
pub fn drawTip(ctx: *Ctx) void {
    if (ctx.tipLen == 0) return;
    ctx.tipBuf[ctx.tipLen] = 0;
    const s: [:0]const u8 = ctx.tipBuf[0..ctx.tipLen :0];
    const w = hudx.textW(s, 15);
    var x: i32 = @as(i32, @intFromFloat(ctx.mouse.x)) + 16;
    var y: i32 = @as(i32, @intFromFloat(ctx.mouse.y)) + 22;
    x = @min(x, rl.getScreenWidth() - w - 24);
    y = @min(y, rl.getScreenHeight() - 36);
    hudx.pill(x - 8, y - 4, w + 16, 27, withAlpha(theme.ink, 235));
    hudx.text(s, x, y, 15, rgba(235, 222, 198, 255));
}

pub fn rect(x: i32, y: i32, w: i32, h: i32) rl.Rectangle {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
}

// Panel that also claims its rect as chrome: without anyHot, world clicks fall
// through the padding onto the map. Claim+panel travel together so the
// click-through hole can't silently reopen.
pub fn claimedPanel(ctx: *Ctx, r: rl.Rectangle, title: ?[:0]const u8) void {
    _ = ctx.hot(r);
    panel(r, title);
}

// Iron panel with a brass liner; optional small-caps title tab.
pub fn panel(r: rl.Rectangle, title: ?[:0]const u8) void {
    rl.drawRectangleRounded(r, 0.08, 6, rgba(10, 8, 7, 215));
    rl.drawRectangleRoundedLinesEx(r, 0.08, 6, 1, withAlpha(theme.trimColor, 120));
    if (title) |t| {
        hudx.text(t, @intFromFloat(r.x + 10), @intFromFloat(r.y + 6), 16, withAlpha(theme.trimColor, 230));
    }
}

// Clickable text button; `active` latches it (brass fill) for palettes/tabs.
// Returns true on click.
pub fn button(ctx: *Ctx, r: rl.Rectangle, label: [:0]const u8, size: i32, active: bool) bool {
    const h = ctx.hot(r);
    const base = if (active) rgba(96, 74, 40, 235) else rgba(24, 19, 15, 225);
    const face = if (h and !active) rgba(38, 30, 23, 235) else base;
    rl.drawRectangleRounded(r, 0.25, 4, face);
    rl.drawRectangleRoundedLinesEx(r, 0.25, 4, 1, withAlpha(theme.trimColor, if (active) 220 else if (h) 170 else 90));
    const tw = hudx.textW(label, size);
    const tx: i32 = @intFromFloat(r.x + (r.width - @as(f32, @floatFromInt(tw))) / 2);
    const ty: i32 = @intFromFloat(r.y + (r.height - @as(f32, @floatFromInt(size))) / 2 - 2);
    hudx.text(label, tx, ty, size, if (active) theme.highlightColor else rgba(225, 212, 190, 240));
    return h and ctx.pressed;
}

// Auto-width chip (variant pickers). Returns clicked; writes its used width so
// callers can flow chips in a row.
pub fn chip(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, active: bool, usedW: *i32) bool {
    const w = hudx.textW(label, 15) + 16;
    usedW.* = w + 6;
    return button(ctx, rect(x, y, w, 24), label, 15, active);
}

// [-] value [+] stepper row, one geometry + clamp-guard for both value types so the
// float and int rows stacked in a panel can't drift apart. Reports a change only when
// the CLAMPED value moved: +/- at a bound must not bank a no-op undo step or raise
// the dirty flag (spurious "unsaved" confirm).
fn stepper(comptime T: type, ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, v: *T, step: T, min: T, max: T) bool {
    const clamp = comptime if (T == f32) mathx.clampF else mathx.clampI;
    hudx.text(label, x, y + 3, 15, withAlpha(theme.labelColor, 230));
    const bx = x + 92;
    var changed = false;
    if (button(ctx, rect(bx, y, 22, 22), "-", 16, false)) {
        const nv = clamp(v.* - step, min, max);
        if (nv != v.*) {
            v.* = nv;
            changed = true;
        }
    }
    var buf: [24]u8 = undefined;
    const fmt = comptime if (T == f32) "{d:.1}" else "{d}";
    const s = std.fmt.bufPrintZ(&buf, fmt, .{v.*}) catch "";
    hudx.text(s, bx + 30 + @divTrunc(34 - hudx.textW(s, 16), 2), y + 3, 16, theme.valueColor);
    if (button(ctx, rect(bx + 96, y, 22, 22), "+", 16, false)) {
        const nv = clamp(v.* + step, min, max);
        if (nv != v.*) {
            v.* = nv;
            changed = true;
        }
    }
    return changed;
}

// Returns true when the value changed.
pub fn stepperF(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, v: *f32, step: f32, min: f32, max: f32) bool {
    return stepper(f32, ctx, x, y, label, v, step, min, max);
}

pub fn stepperI(ctx: *Ctx, x: i32, y: i32, label: [:0]const u8, v: *i32, min: i32, max: i32) bool {
    return stepper(i32, ctx, x, y, label, v, 1, min, max);
}

// A color swatch (palette presets). Returns clicked.
pub fn swatch(ctx: *Ctx, x: i32, y: i32, w: i32, h: i32, fill: rl.Color, edge: rl.Color, active: bool) bool {
    const r = rect(x, y, w, h);
    const hov = ctx.hot(r);
    rl.drawRectangleRounded(r, 0.25, 4, fill);
    rl.drawRectangleRoundedLinesEx(r, 0.25, 4, if (active) 2 else 1, if (active) theme.highlightColor else if (hov) withAlpha(theme.trimColor, 220) else edge);
    return hov and ctx.pressed;
}

// Single-line text field. Caller owns focus; while focused, consumes typed chars
// and backspace. Draws a breathing caret.
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
    hudx.text(s, @intFromFloat(r.x + 8), @intFromFloat(r.y + 4), 18, theme.valueColor);
    if (focused and @mod(t, 1.0) < 0.55) {
        const cx: i32 = @as(i32, @intFromFloat(r.x)) + 10 + hudx.textW(s, 18);
        rl.drawRectangle(cx, @intFromFloat(r.y + 5), 2, 18, withAlpha(theme.highlightColor, 220));
    }
}

// Modal scaffold: dim screen, center a panel, return its top-left as PIXEL ints
// (callers lay out in ints). The backdrop eats the pointer (anyHot) so nothing
// behind it is clickable.
pub const ModalBox = struct { x: i32, y: i32 };

pub fn beginModal(ctx: *Ctx, w: i32, h: i32, title: [:0]const u8) ModalBox {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.drawRectangle(0, 0, sw, sh, rgba(0, 0, 0, 140));
    ctx.anyHot = true; // a modal owns the pointer wholesale
    const x = @divTrunc(sw - w, 2);
    const y = @divTrunc(sh - h, 2);
    panel(rect(x, y, w, h), null);
    hudx.text(title, x + @divTrunc(w - hudx.textW(title, 20), 2), y + 12, 20, theme.titleColor);
    return .{ .x = x, .y = y };
}
