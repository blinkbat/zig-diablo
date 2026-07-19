const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const ui = @import("ui.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");
const mapmod = @import("map.zig");
const trig = @import("trigger.zig");
const player = @import("player.zig");
const monster = @import("monster.zig");
const gamemod = @import("game.zig");

const Game = gamemod.Game;
const rgba = mathx.rgba;
const withAlpha = mathx.withAlpha;

// CLASSIC TRIGEDIT — the StarCraft StarEdit-style trigger editor, adapted to the ARPG town.
// A trigger is { conditions[], actions[] }; all conditions must hold, then actions run top→
// bottom. Conversations ARE triggers (say/choice actions drive the dialogue box). This is
// the AUTHORING surface: a trigger list, and for the selected trigger, a Conditions list and
// an Actions list where each row is an English sentence with clickable parameter slots — a
// discrete slot CYCLES to the next value on click, a number slot has [-]/[+], and a text slot
// opens an editor popup. Switches/counters are named in a small manager; regions and NPCs are
// placed in the main editor and referenced here by name.
//
// Reads/writes g.map.trig (a trig.Store) + g.map.regions/npcs directly, so the editor's
// whole-Map undo and .map persistence cover every edit for free.

// ── Transient UI state (this surface owns the screen while open) ──
const TypePick = enum { none, cond, act };
var typePick: TypePick = .none;
var namesMgr: bool = false;
var scrollCond: f32 = 0;
var scrollAct: f32 = 0;
var lastSel: usize = std.math.maxInt(usize);

// A pending text edit: which name/string the popup is editing. Resolved to storage each frame
// by index, never a stored pointer (indices stay valid; a pointer could dangle across undo).
const TextTarget = union(enum) {
    string: u16,
    switch_name: u16,
    counter_name: u16,
    trig_name: usize,
};
var textEditing: ?TextTarget = null;

const FS: i32 = 18; // trigger-editor row font size — larger than the editor's default chrome
const CHIP_H: i32 = 28; // brass chip height at FS
const ROW_H: i32 = 34; // condition/action row pitch (chip height + gap)

pub fn update(g: *Game) void {
    const ed = &g.ed;
    // Esc unwinds one layer at a time: popup → picker → the whole surface.
    if (rl.isKeyPressed(.escape)) {
        if (textEditing != null) {
            textEditing = null;
        } else if (typePick != .none) {
            typePick = .none;
        } else if (namesMgr) {
            namesMgr = false;
        } else {
            ed.trigOpen = false;
        }
    }
}

pub fn draw(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    const W = rl.getScreenWidth();
    const H = rl.getScreenHeight();

    // Dim the 3D editor scene behind us into a backdrop.
    rl.drawRectangle(0, 0, W, H, rgba(6, 6, 9, 232));
    ctx.anyHot = true; // this surface owns the pointer wholesale

    hudx.text("TRIGGERS", 24, 18, 26, theme.titleColor);
    hudx.text("StarEdit-style: conditions must ALL hold, then actions run top to bottom. Click a highlighted slot to change it.", 210, 26, 14, withAlpha(theme.labelColor, 210));
    if (ui.button(ctx, ui.rect(W - 108, 16, 84, 28), "Close", 17, false)) {
        ed.trigOpen = false;
        return;
    }

    // Keep the selection in range as triggers are added/removed.
    const store = &g.map.trig;
    if (store.trigger_count == 0) {
        ed.trigSel = 0;
    } else if (ed.trigSel >= store.trigger_count) {
        ed.trigSel = store.trigger_count - 1;
    }
    if (ed.trigSel != lastSel) {
        scrollCond = 0;
        scrollAct = 0;
        lastSel = ed.trigSel;
    }

    drawTriggerList(g, ctx, H);
    if (store.trigger_count > 0) drawSelected(g, ctx, W, H);

    // Popups over everything.
    if (namesMgr) drawNamesMgr(g, ctx);
    if (typePick != .none) drawTypePicker(g, ctx);
    if (textEditing != null) drawTextPopup(g, ctx);
}

// ── Left: the trigger list ──
fn drawTriggerList(g: *Game, ctx: *ui.Ctx, H: i32) void {
    const ed = &g.ed;
    const store = &g.map.trig;
    const lx: i32 = 24;
    const lw: i32 = 300;
    const top: i32 = 60;
    ui.panel(ui.rect(lx, top, lw, H - top - 24), "TRIGGERS");

    var bx = lx + 12;
    if (ui.button(ctx, ui.rect(bx, top + 30, 60, 26), "New", 16, false)) {
        if (store.addTrigger("New Trigger")) |_| {
            ed.trigSel = store.trigger_count - 1;
            g.ed.dirty = true;
        }
    }
    bx += 66;
    if (ui.button(ctx, ui.rect(bx, top + 30, 66, 26), "Dup", 16, false)) duplicate(g);
    bx += 72;
    if (ui.button(ctx, ui.rect(bx, top + 30, 84, 26), "Delete", 16, false)) {
        if (store.trigger_count > 0) {
            store.removeTrigger(ed.trigSel);
            g.ed.dirty = true;
        }
    }

    const listY = top + 66;
    const listH = H - listY - 32;
    var y = listY;
    for (store.triggerList(), 0..) |*t, i| {
        if (y > listY + listH - ROW_H) break; // simple clip (no scroll: MAX_TRIGGERS fits tall)
        const r = ui.rect(lx + 10, y, lw - 20, ROW_H - 4);
        const sel = i == ed.trigSel;
        if (ui.button(ctx, r, "", 15, sel)) ed.trigSel = i;
        var buf: [56]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&buf, "{d}. {s}", .{ i + 1, t.name.slice() }) catch "";
        hudx.text(nm, lx + 20, y + 6, 17, if (sel) theme.highlightColor else rgba(214, 202, 182, 235));
        var cbuf: [24]u8 = undefined;
        const cnt = std.fmt.bufPrintZ(&cbuf, "{d}c {d}a", .{ t.cond_count, t.act_count }) catch "";
        hudx.text(cnt, lx + lw - 72, y + 7, 14, withAlpha(theme.labelColor, 200));
        y += ROW_H;
    }
    if (store.trigger_count == 0) {
        hudx.text("No triggers yet — click New.", lx + 20, listY + 6, 15, withAlpha(theme.labelColor, 200));
    }
}

fn duplicate(g: *Game) void {
    const store = &g.map.trig;
    if (store.trigger_count == 0) return;
    if (store.trigger_count >= trig.MAX_TRIGGERS) return;
    const src = store.triggers[g.ed.trigSel];
    store.triggers[store.trigger_count] = src;
    store.trigger_count += 1;
    g.ed.trigSel = store.trigger_count - 1;
    g.ed.dirty = true;
}

// ── Right: the selected trigger (conditions + actions) ──
fn drawSelected(g: *Game, ctx: *ui.Ctx, W: i32, H: i32) void {
    const ed = &g.ed;
    const store = &g.map.trig;
    const rx: i32 = 344;
    const rw: i32 = W - rx - 24;
    const top: i32 = 60;

    // Header: trigger name (click to rename) + Names… manager.
    ui.panel(ui.rect(rx, top, rw, 44), null);
    var hx = rx + 14;
    hudx.text("Trigger:", hx, top + 13, 16, withAlpha(theme.labelColor, 230));
    hx += 74;
    {
        var buf: [56]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&buf, "{s}", .{store.triggers[ed.trigSel].name.slice()}) catch "";
        var used: i32 = 0;
        if (chipW(ctx, hx, top + 8, nm, &used)) openText(g, .{ .trig_name = ed.trigSel });
    }
    if (ui.button(ctx, ui.rect(rx + rw - 108, top + 8, 96, 28), "Names...", 15, false)) namesMgr = true;

    const t = &store.triggers[ed.trigSel];

    // Conditions box (top ~40%).
    const condTop = top + 54;
    const condH = @divTrunc((H - condTop - 40) * 4, 10);
    ui.panel(ui.rect(rx, condTop, rw, condH), "CONDITIONS  (all must hold)");
    scrollCond = drawRows(g, ctx, t, false, rx, condTop + 28, rw, condH - 60, scrollCond);
    if (ui.button(ctx, ui.rect(rx + 12, condTop + condH - 30, 150, 24), "+ Add condition", 15, false)) typePick = .cond;

    // Actions box (bottom ~60%).
    const actTop = condTop + condH + 14;
    const actH = H - actTop - 26;
    ui.panel(ui.rect(rx, actTop, rw, actH), "ACTIONS  (run top to bottom)");
    scrollAct = drawRows(g, ctx, t, true, rx, actTop + 28, rw, actH - 60, scrollAct);
    if (ui.button(ctx, ui.rect(rx + 12, actTop + actH - 30, 150, 24), "+ Add action", 15, false)) typePick = .act;
}

// Draw a trigger's condition or action rows inside a scrollable band; returns the new scroll.
// Rows outside the band are skipped entirely (no draw, no hit-test) so nothing phantom-clicks.
fn drawRows(g: *Game, ctx: *ui.Ctx, t: *trig.Trigger, actions: bool, rx: i32, ay: i32, rw: i32, ah: i32, scroll_in: f32) f32 {
    const count = if (actions) t.act_count else t.cond_count;
    var scroll = scroll_in;

    // Wheel scroll when the pointer is over the band.
    const mouse = rl.getMousePosition();
    const overBand = mouse.x >= @as(f32, @floatFromInt(rx)) and mouse.x <= @as(f32, @floatFromInt(rx + rw)) and
        mouse.y >= @as(f32, @floatFromInt(ay)) and mouse.y <= @as(f32, @floatFromInt(ay + ah));
    if (overBand) scroll -= rl.getMouseWheelMove() * 34;
    const total: f32 = @floatFromInt(@as(i32, @intCast(count)) * ROW_H);
    const maxScroll = @max(0.0, total - @as(f32, @floatFromInt(ah)));
    scroll = std.math.clamp(scroll, 0, maxScroll);

    var depth: i32 = 0; // choice/end_choice nesting, for indentation
    var removed = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // An end_choice dedents BEFORE it draws.
        if (actions and t.acts[i] == .end_choice and depth > 0) depth -= 1;
        const y = ay + @as(i32, @intFromFloat(-scroll)) + @as(i32, @intCast(i)) * ROW_H;
        const indent = depth * 20;
        if (y >= ay - ROW_H and y <= ay + ah) {
            if (actions) {
                if (drawActRow(g, ctx, t, i, rx + 14 + indent, y, rw - 28 - indent)) {
                    removed = true;
                    break;
                }
            } else {
                if (drawCondRow(g, ctx, t, i, rx + 14, y, rw - 28)) {
                    removed = true;
                    break;
                }
            }
        }
        if (actions and t.acts[i] == .choice) depth += 1;
    }
    if (removed) g.ed.dirty = true;
    return scroll;
}

// ── Row rendering helpers ──
// Fixed sentence word; advances cx.
fn word(cx: *i32, y: i32, s: [:0]const u8) void {
    hudx.text(s, cx.*, y + 6, FS, withAlpha(rgba(228, 218, 198, 255), 235));
    cx.* += hudx.textW(s, FS) + 9;
}

// A brass chip at the editor font size; returns clicked and writes its advance width. (Local,
// not ui.chip, so the trigger editor can run a larger font than the rest of the editor chrome.)
fn chipW(ctx: *ui.Ctx, x: i32, y: i32, label: [:0]const u8, usedW: *i32) bool {
    const w = hudx.textW(label, FS) + 18;
    usedW.* = w + 6;
    return ui.button(ctx, ui.rect(x, y, w, CHIP_H), label, FS, false);
}

// Clickable brass chip; advances cx; returns clicked.
fn chip(ctx: *ui.Ctx, cx: *i32, y: i32, label: [:0]const u8) bool {
    var used: i32 = 0;
    const hit = chipW(ctx, cx.*, y, label, &used);
    cx.* += used;
    return hit;
}

fn zLabel(buf: []u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn cycleU16(id: *u16, count: usize) void {
    if (count > 0) id.* = @intCast((@as(usize, id.*) + 1) % count);
}

fn cycleEnum(comptime T: type, v: *T) void {
    const n = @typeInfo(T).@"enum".fields.len;
    v.* = @enumFromInt((@as(usize, @intFromEnum(v.*)) + 1) % n);
}

fn npcChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: *u16) void {
    var buf: [40]u8 = undefined;
    const nm = if (id.* < g.map.npc_count) g.map.npcs[id.*].name.slice() else "(no NPC)";
    if (chip(ctx, cx, y, zLabel(&buf, nm))) cycleU16(id, g.map.npc_count);
}
fn regionChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: *u16) void {
    var buf: [40]u8 = undefined;
    const nm = if (id.* < g.map.region_count) g.map.regions[id.*].name.slice() else "(no region)";
    if (chip(ctx, cx, y, zLabel(&buf, nm))) cycleU16(id, g.map.region_count);
}
fn switchChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: *u16) void {
    var buf: [40]u8 = undefined;
    const nm = if (id.* < g.map.trig.switch_count) g.map.trig.switchName(id.*) else "(no switch)";
    if (chip(ctx, cx, y, zLabel(&buf, nm))) cycleU16(id, g.map.trig.switch_count);
}
fn counterChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: *u16) void {
    var buf: [40]u8 = undefined;
    const nm = if (id.* < g.map.trig.counter_count) g.map.trig.counterName(id.*) else "(no counter)";
    if (chip(ctx, cx, y, zLabel(&buf, nm))) cycleU16(id, g.map.trig.counter_count);
}
fn triggerChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: *u16) void {
    var buf: [40]u8 = undefined;
    const nm = if (id.* < g.map.trig.trigger_count) g.map.trig.triggers[id.*].name.slice() else "(no trigger)";
    if (chip(ctx, cx, y, zLabel(&buf, nm))) cycleU16(id, g.map.trig.trigger_count);
}
fn enumChip(comptime T: type, ctx: *ui.Ctx, cx: *i32, y: i32, v: *T) void {
    if (chip(ctx, cx, y, @tagName(v.*))) cycleEnum(T, v);
}

fn numChip(ctx: *ui.Ctx, cx: *i32, y: i32, v: *i32, lo: i32, hi: i32) void {
    if (chip(ctx, cx, y, "-")) v.* = @max(lo, v.* - 1);
    var b: [12]u8 = undefined;
    word(cx, y, std.fmt.bufPrintZ(&b, "{d}", .{v.*}) catch "0");
    if (chip(ctx, cx, y, "+")) v.* = @min(hi, v.* + 1);
}
fn numChipF(ctx: *ui.Ctx, cx: *i32, y: i32, v: *f32) void {
    if (chip(ctx, cx, y, "-")) v.* = @max(0, v.* - 1);
    var b: [16]u8 = undefined;
    word(cx, y, std.fmt.bufPrintZ(&b, "{d:.0}", .{v.*}) catch "0");
    if (chip(ctx, cx, y, "+")) v.* += 1;
}
fn strChip(g: *Game, ctx: *ui.Ctx, cx: *i32, y: i32, id: u16) void {
    var qb: [40]u8 = undefined;
    const raw = g.map.trig.stringText(id);
    const n = @min(raw.len, 26);
    const s = std.fmt.bufPrintZ(&qb, "\"{s}{s}\"", .{ raw[0..n], if (raw.len > n) ".." else "" }) catch "\"\"";
    if (chip(ctx, cx, y, s)) openText(g, .{ .string = id });
}

// Delete button parked at the row's right edge. Returns clicked.
fn delBtn(ctx: *ui.Ctx, x: i32, y: i32) bool {
    return ui.button(ctx, ui.rect(x, y, 26, 26), "x", 17, false);
}

fn drawCondRow(g: *Game, ctx: *ui.Ctx, t: *trig.Trigger, ci: usize, x: i32, y: i32, w: i32) bool {
    var cx = x;
    const c = &t.conds[ci];
    switch (c.*) {
        .always => word(&cx, y, "Always"),
        .never => word(&cx, y, "Never"),
        .switch_on => |*id| {
            word(&cx, y, "Switch");
            switchChip(g, ctx, &cx, y, id);
            word(&cx, y, "is SET");
        },
        .switch_off => |*id| {
            word(&cx, y, "Switch");
            switchChip(g, ctx, &cx, y, id);
            word(&cx, y, "is CLEAR");
        },
        .counter => |*p| {
            word(&cx, y, "Counter");
            counterChip(g, ctx, &cx, y, &p.c);
            enumChip(trig.Op, ctx, &cx, y, &p.op);
            numChip(ctx, &cx, y, &p.n, -9999, 9999);
        },
        .in_region => |*id| {
            word(&cx, y, "Player in region");
            regionChip(g, ctx, &cx, y, id);
        },
        .near_npc => |*id| {
            word(&cx, y, "Player near");
            npcChip(g, ctx, &cx, y, id);
        },
        .talked_to => |*id| {
            word(&cx, y, "Has talked to");
            npcChip(g, ctx, &cx, y, id);
        },
        .on_talk => |*id| {
            word(&cx, y, "On talk to");
            npcChip(g, ctx, &cx, y, id);
        },
        .player_level => |*p| {
            word(&cx, y, "Player level");
            enumChip(trig.Op, ctx, &cx, y, &p.op);
            numChip(ctx, &cx, y, &p.n, 1, 99);
        },
        .elapsed => |*p| {
            word(&cx, y, "Time elapsed");
            enumChip(trig.Op, ctx, &cx, y, &p.op);
            numChipF(ctx, &cx, y, &p.secs);
            word(&cx, y, "sec");
        },
    }
    if (delBtn(ctx, x + w - 26, y)) {
        removeAt(trig.Cond, &t.conds, &t.cond_count, ci);
        return true;
    }
    return false;
}

fn drawActRow(g: *Game, ctx: *ui.Ctx, t: *trig.Trigger, ai: usize, x: i32, y: i32, w: i32) bool {
    var cx = x;
    const a = &t.acts[ai];
    switch (a.*) {
        .say => |*p| {
            word(&cx, y, "Say (as");
            npcChip(g, ctx, &cx, y, &p.npc);
            word(&cx, y, ")");
            strChip(g, ctx, &cx, y, p.text);
        },
        .choice => |*id| {
            word(&cx, y, "Choice:");
            strChip(g, ctx, &cx, y, id.*);
        },
        .end_choice => word(&cx, y, "end choice"),
        .end_dialogue => word(&cx, y, "End dialogue"),
        .message => |*id| {
            word(&cx, y, "Message:");
            strChip(g, ctx, &cx, y, id.*);
        },
        .set_switch => |*p| {
            word(&cx, y, "Set switch");
            switchChip(g, ctx, &cx, y, &p.s);
            enumChip(trig.SwitchMode, ctx, &cx, y, &p.mode);
        },
        .set_counter => |*p| {
            word(&cx, y, "Counter");
            counterChip(g, ctx, &cx, y, &p.c);
            enumChip(trig.CounterMode, ctx, &cx, y, &p.mode);
            numChip(ctx, &cx, y, &p.n, -9999, 9999);
        },
        .grant_skill => |*sk| {
            word(&cx, y, "Grant skill");
            enumChip(player.Skill, ctx, &cx, y, sk);
        },
        .spawn => |*p| {
            word(&cx, y, "Spawn");
            enumChip(monster.MonsterKind, ctx, &cx, y, &p.kind);
            word(&cx, y, "x");
            numChip(ctx, &cx, y, &p.count, 1, 32);
            word(&cx, y, "in");
            regionChip(g, ctx, &cx, y, &p.region);
        },
        .teleport => |*id| {
            word(&cx, y, "Teleport player to");
            regionChip(g, ctx, &cx, y, id);
        },
        .center_cam => |*id| {
            word(&cx, y, "Center camera on");
            regionChip(g, ctx, &cx, y, id);
        },
        .set_objective => |*id| {
            word(&cx, y, "Set objective:");
            strChip(g, ctx, &cx, y, id.*);
        },
        .run_trigger => |*id| {
            word(&cx, y, "Run trigger");
            triggerChip(g, ctx, &cx, y, id);
        },
        .preserve => word(&cx, y, "Preserve trigger (re-arm)"),
    }
    if (delBtn(ctx, x + w - 26, y)) {
        removeAt(trig.Act, &t.acts, &t.act_count, ai);
        return true;
    }
    return false;
}

// Order-preserving remove from a fixed array (act order is load-bearing — choice brackets).
fn removeAt(comptime T: type, arr: anytype, count: *usize, i: usize) void {
    _ = T;
    var j = i;
    while (j + 1 < count.*) : (j += 1) arr[j] = arr[j + 1];
    count.* -= 1;
}

// ── The type picker popup (add a condition / action) ──
const COND_TYPES = [_]struct { t: trig.Cond, label: [:0]const u8 }{
    .{ .t = .always, .label = "Always" },
    .{ .t = .never, .label = "Never" },
    .{ .t = .{ .switch_on = 0 }, .label = "Switch is set" },
    .{ .t = .{ .switch_off = 0 }, .label = "Switch is clear" },
    .{ .t = .{ .counter = .{ .c = 0, .op = .at_least, .n = 1 } }, .label = "Counter compare" },
    .{ .t = .{ .in_region = 0 }, .label = "Player in region" },
    .{ .t = .{ .near_npc = 0 }, .label = "Player near NPC" },
    .{ .t = .{ .talked_to = 0 }, .label = "Has talked to NPC" },
    .{ .t = .{ .on_talk = 0 }, .label = "On talk to NPC" },
    .{ .t = .{ .player_level = .{ .op = .at_least, .n = 2 } }, .label = "Player level" },
    .{ .t = .{ .elapsed = .{ .op = .at_least, .secs = 5 } }, .label = "Time elapsed" },
};

const ACT_TYPES = [_]struct { tag: std.meta.Tag(trig.Act), label: [:0]const u8 }{
    .{ .tag = .say, .label = "Say (dialogue line)" },
    .{ .tag = .choice, .label = "Choice (branch button)" },
    .{ .tag = .end_choice, .label = "End choice" },
    .{ .tag = .end_dialogue, .label = "End dialogue" },
    .{ .tag = .message, .label = "Message (banner)" },
    .{ .tag = .set_switch, .label = "Set switch" },
    .{ .tag = .set_counter, .label = "Set counter" },
    .{ .tag = .grant_skill, .label = "Grant skill" },
    .{ .tag = .spawn, .label = "Spawn monsters" },
    .{ .tag = .teleport, .label = "Teleport player" },
    .{ .tag = .center_cam, .label = "Center camera" },
    .{ .tag = .set_objective, .label = "Set objective" },
    .{ .tag = .run_trigger, .label = "Run trigger" },
    .{ .tag = .preserve, .label = "Preserve trigger" },
};

// The pickers are hand-maintained; pin their length to the union so a new Cond/Act variant
// is a compile error here (not a variant silently missing from the Add menus).
comptime {
    std.debug.assert(COND_TYPES.len == @typeInfo(std.meta.Tag(trig.Cond)).@"enum".fields.len);
    std.debug.assert(ACT_TYPES.len == @typeInfo(std.meta.Tag(trig.Act)).@"enum".fields.len);
}

fn drawTypePicker(g: *Game, ctx: *ui.Ctx) void {
    const isCond = typePick == .cond;
    const n: i32 = if (isCond) COND_TYPES.len else ACT_TYPES.len;
    const cols: i32 = 2;
    const rows = @divTrunc(n + cols - 1, cols);
    const mb = ui.beginModal(ctx, 480, 96 + rows * 34, if (isCond) "Add condition" else "Add action");
    var idx: i32 = 0;
    while (idx < n) : (idx += 1) {
        const cxp = mb.x + 20 + @mod(idx, cols) * 224;
        const cyp = mb.y + 52 + @divTrunc(idx, cols) * 34;
        const label = if (isCond) COND_TYPES[@intCast(idx)].label else ACT_TYPES[@intCast(idx)].label;
        if (ui.button(ctx, ui.rect(cxp, cyp, 212, 28), label, 15, false)) {
            if (isCond) addCond(g, COND_TYPES[@intCast(idx)].t) else addAct(g, ACT_TYPES[@intCast(idx)].tag);
            typePick = .none;
            return;
        }
    }
    if (ui.button(ctx, ui.rect(mb.x + 190, mb.y + 56 + rows * 34, 100, 28), "Cancel", 16, false)) typePick = .none;
}

fn addCond(g: *Game, c: trig.Cond) void {
    const t = &g.map.trig.triggers[g.ed.trigSel];
    if (t.cond_count >= trig.MAX_TRIG_CONDS) return;
    var cc = c;
    // Point switch/counter refs at a real slot (creating one if the map has none yet).
    switch (cc) {
        .switch_on, .switch_off => |*id| id.* = ensureSwitch(g),
        .counter => |*p| p.c = ensureCounter(g),
        else => {},
    }
    t.conds[t.cond_count] = cc;
    t.cond_count += 1;
    g.ed.dirty = true;
}

fn addAct(g: *Game, tag: std.meta.Tag(trig.Act)) void {
    const store = &g.map.trig;
    const t = &store.triggers[g.ed.trigSel];
    if (t.act_count >= trig.MAX_TRIG_ACTS) return;
    const a: trig.Act = switch (tag) {
        // orelse return on a full string pool: appending an action that aliases string 0
        // would corrupt that slot when the user later edits this action's text.
        .say => .{ .say = .{ .npc = 0, .text = store.addString("New line.") orelse return } },
        .choice => .{ .choice = store.addString("Choice") orelse return },
        .end_choice => .end_choice,
        .end_dialogue => .end_dialogue,
        .message => .{ .message = store.addString("Message.") orelse return },
        .set_switch => .{ .set_switch = .{ .s = ensureSwitch(g), .mode = .on } },
        .set_counter => .{ .set_counter = .{ .c = ensureCounter(g), .mode = .set, .n = 1 } },
        .grant_skill => .{ .grant_skill = .firebolt },
        .spawn => .{ .spawn = .{ .kind = .fallen, .count = 3, .region = 0 } },
        .teleport => .{ .teleport = 0 },
        .center_cam => .{ .center_cam = 0 },
        .set_objective => .{ .set_objective = store.addString("Objective.") orelse return },
        .run_trigger => .{ .run_trigger = 0 },
        .preserve => .preserve,
    };
    t.acts[t.act_count] = a;
    t.act_count += 1;
    g.ed.dirty = true;
}

fn ensureSwitch(g: *Game) u16 {
    const store = &g.map.trig;
    if (store.switch_count == 0) return store.addSwitch("Switch 1") orelse 0;
    return 0;
}
fn ensureCounter(g: *Game) u16 {
    const store = &g.map.trig;
    if (store.counter_count == 0) return store.addCounter("Counter 1") orelse 0;
    return 0;
}

// ── Switches & counters manager ──
fn drawNamesMgr(g: *Game, ctx: *ui.Ctx) void {
    const store = &g.map.trig;
    const mb = ui.beginModal(ctx, 560, 440, "Switches & Counters");
    hudx.text("Switches (boolean flags)", mb.x + 24, mb.y + 44, 16, theme.titleColor);
    if (ui.button(ctx, ui.rect(mb.x + 250, mb.y + 40, 90, 24), "+ Add", 15, false)) {
        var b: [20]u8 = undefined;
        _ = store.addSwitch(std.fmt.bufPrint(&b, "Switch {d}", .{store.switch_count + 1}) catch "Switch");
        g.ed.dirty = true;
    }
    var y = mb.y + 72;
    for (store.switch_names[0..store.switch_count], 0..) |*nm, i| {
        var buf: [40]u8 = undefined;
        var used: i32 = 0;
        if (chipW(ctx, mb.x + 40, y, zLabel(&buf, nm.slice()), &used)) openText(g, .{ .switch_name = @intCast(i) });
        y += 30;
        if (y > mb.y + 200) break;
    }

    hudx.text("Counters (integers)", mb.x + 24, mb.y + 224, 16, theme.titleColor);
    if (ui.button(ctx, ui.rect(mb.x + 250, mb.y + 220, 90, 24), "+ Add", 15, false)) {
        var b: [20]u8 = undefined;
        _ = store.addCounter(std.fmt.bufPrint(&b, "Counter {d}", .{store.counter_count + 1}) catch "Counter");
        g.ed.dirty = true;
    }
    y = mb.y + 252;
    for (store.counter_names[0..store.counter_count], 0..) |*nm, i| {
        var buf: [40]u8 = undefined;
        var used: i32 = 0;
        if (chipW(ctx, mb.x + 40, y, zLabel(&buf, nm.slice()), &used)) openText(g, .{ .counter_name = @intCast(i) });
        y += 30;
        if (y > mb.y + 380) break;
    }

    if (ui.button(ctx, ui.rect(mb.x + 234, mb.y + 398, 96, 28), "Close", 16, false)) namesMgr = false;
}

// ── Text edit popup (dialogue lines, switch/counter/trigger names) ──
fn openText(g: *Game, target: TextTarget) void {
    const ed = &g.ed;
    const s = textOf(g, target);
    const n = @min(s.len, ed.field_buf.len);
    @memcpy(ed.field_buf[0..n], s[0..n]);
    ed.field_len = n;
    textEditing = target;
}

fn textOf(g: *Game, target: TextTarget) []const u8 {
    const store = &g.map.trig;
    return switch (target) {
        .string => |id| store.stringText(id),
        .switch_name => |id| store.switchName(id),
        .counter_name => |id| store.counterName(id),
        .trig_name => |i| if (i < store.trigger_count) store.triggers[i].name.slice() else "",
    };
}

fn commitText(g: *Game) void {
    const target = textEditing orelse return;
    const store = &g.map.trig;
    const s = g.ed.field_buf[0..g.ed.field_len];
    switch (target) {
        .string => |id| if (id < store.string_count) store.strings[id].set(s),
        .switch_name => |id| if (id < store.switch_count) store.switch_names[id].set(s),
        .counter_name => |id| if (id < store.counter_count) store.counter_names[id].set(s),
        .trig_name => |i| if (i < store.trigger_count) store.triggers[i].name.set(s),
    }
    textEditing = null;
    g.ed.dirty = true;
}

fn drawTextPopup(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    const mb = ui.beginModal(ctx, 520, 156, "Edit text");
    ui.textField(ctx, ui.rect(mb.x + 24, mb.y + 56, 472, 32), &ed.field_buf, &ed.field_len, true, g.elapsed);
    if (ui.button(ctx, ui.rect(mb.x + 300, mb.y + 106, 90, 30), "OK", 17, false) or rl.isKeyPressed(.enter)) commitText(g);
    if (ui.button(ctx, ui.rect(mb.x + 400, mb.y + 106, 96, 30), "Cancel", 17, false)) textEditing = null;
}
