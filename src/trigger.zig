const std = @import("std");
const mathx = @import("mathx.zig");
const player = @import("player.zig");
const monster = @import("monster.zig");

// TRIGGERS — the town/quest logic layer, modeled on StarCraft's StarEdit "Classic
// Trigedit". A trigger is { conditions[], actions[] }: ALL conditions must hold (AND,
// top→bottom), then the actions run top→bottom. A trigger fires once and is spent
// unless its actions include `preserve` (StarEdit's Preserve Trigger), which re-arms it.
//
// CONVERSATIONS ARE TRIGGERS. There is no separate dialogue format: a conversation is a
// trigger whose action script drives the in-game dialogue box. `say`/`choice`/`end_choice`
// build the box; a `choice` branches by bracketing the actions that run when it's picked
// (flat list, `choice … end_choice`, no recursion). Any action — set a switch, grant a
// skill, spawn foes, run another trigger — can appear anywhere.
//
// This module owns the DATA + on-disk (de)serialization only; it is game-agnostic (imports
// nothing that imports it). The runtime evaluator + effects live in game.zig, which has the
// player/world/dialogue state the conditions and actions read and write. Authored data is
// serialized; per-run runtime state (which triggers have fired, switch/counter VALUES) is
// NOT — it lives in game.Trigger runtime, reset each playtest/area.

const StrBuf = mathx.StrBuf;
const Tok = std.mem.TokenIterator(u8, .scalar);

// Capacities. Per-trigger conds/acts are stored INLINE (not a shared pool) so the editor
// can insert/remove/reorder a trigger's rows without fixing up other triggers' indices.
// Strings are pooled (referenced by u16 id) so dialogue text — which has spaces — serializes
// cleanly in the line-oriented .map format and isn't duplicated per row.
pub const MAX_TRIGGERS = 48;
pub const MAX_TRIG_CONDS = 12;
pub const MAX_TRIG_ACTS = 48;
pub const MAX_STRINGS = 200;
pub const STRING_CAP = 128; // one dialogue line / message / objective
pub const MAX_SWITCHES = 48;
pub const MAX_COUNTERS = 48;
pub const NAME_CAP = 28; // switch/counter names
pub const TRIG_NAME_CAP = 40;

// Runtime array bounds for per-NPC / per-region flags. Declared here (independent of
// map.zig, which imports this file — the reverse import would cycle); map.zig asserts its
// own MAX_NPCS/MAX_REGIONS don't exceed these.
pub const RT_MAX_NPCS = 24;
pub const RT_MAX_REGIONS = 24;

// The comparison operator every quantity uses (StarEdit's At least / At most / Exactly).
pub const Op = enum(u8) {
    at_least,
    at_most,
    exactly,

    pub fn holds(op: Op, a: i32, b: i32) bool {
        return switch (op) {
            .at_least => a >= b,
            .at_most => a <= b,
            .exactly => a == b,
        };
    }
};

pub const SwitchMode = enum(u8) { on, off, toggle };
pub const CounterMode = enum(u8) { set, add, sub };

// ── Conditions ────────────────────────────────────────────────────────────────
// u16 payloads are indices: switch_on/off → Store.switch_names, counter → Store.counter_names,
// in_region → Map.regions, near_npc/talked_to → Map.npcs.
pub const Cond = union(enum) {
    always,
    never,
    switch_on: u16,
    switch_off: u16,
    counter: Counter,
    in_region: u16, // player currently inside this region (StarEdit "Bring")
    near_npc: u16, // player within talk range of this NPC (passive proximity)
    talked_to: u16, // player has spoken with this NPC this run
    on_talk: u16, // player just pressed talk next to this NPC — the town's "start
    // conversation" edge, true for exactly one eval pass; distinct from passive near_npc
    player_level: Threshold,
    elapsed: Elapsed, // seconds since the area began

    pub const Counter = struct { c: u16, op: Op, n: i32 };
    pub const Threshold = struct { op: Op, n: i32 };
    pub const Elapsed = struct { op: Op, secs: f32 };
};

// ── Actions ───────────────────────────────────────────────────────────────────
pub const Act = union(enum) {
    say: Say, // set the dialogue box speaker+text; opens it and waits for the player
    choice: u16, // add a choice button (label = string id); brackets its branch
    end_choice, // close the branch opened by the matching `choice`
    end_dialogue, // close the box
    message: u16, // center-screen / log line (string id)
    set_switch: SetSwitch,
    set_counter: SetCounter,
    grant_skill: player.Skill, // learn a skill (adds to Player.owned)
    spawn: Spawn, // deploy a monster pack at a region
    teleport: u16, // move the hero to a region's center
    center_cam: u16, // pan the camera to a region's center
    set_objective: u16, // set the current quest-objective text (string id)
    run_trigger: u16, // chain into another trigger (index) — "start conversation X"
    preserve, // re-arm this trigger instead of spending it (StarEdit Preserve)

    pub const Say = struct { npc: u16, text: u16 };
    pub const SetSwitch = struct { s: u16, mode: SwitchMode };
    pub const SetCounter = struct { c: u16, mode: CounterMode, n: i32 };
    pub const Spawn = struct { kind: monster.MonsterKind, count: i32, region: u16 };
};

pub const Trigger = struct {
    name: StrBuf(TRIG_NAME_CAP) = .{},
    conds: [MAX_TRIG_CONDS]Cond = undefined,
    cond_count: usize = 0,
    acts: [MAX_TRIG_ACTS]Act = undefined,
    act_count: usize = 0,

    pub fn condList(t: *const Trigger) []const Cond {
        return t.conds[0..t.cond_count];
    }
    pub fn actList(t: *const Trigger) []const Act {
        return t.acts[0..t.act_count];
    }
};

// All authored trigger logic for a map. Embedded by value in map.Map (fixed arrays, no
// pointers) so the editor's whole-Map undo snapshot and live-preview cover it for free.
pub const Store = struct {
    strings: [MAX_STRINGS]StrBuf(STRING_CAP) = undefined,
    string_count: usize = 0,
    switch_names: [MAX_SWITCHES]StrBuf(NAME_CAP) = undefined,
    switch_count: usize = 0,
    counter_names: [MAX_COUNTERS]StrBuf(NAME_CAP) = undefined,
    counter_count: usize = 0,
    triggers: [MAX_TRIGGERS]Trigger = undefined,
    trigger_count: usize = 0,

    pub fn triggerList(s: *const Store) []const Trigger {
        return s.triggers[0..s.trigger_count];
    }

    // Append a string to the pool, returning its id (or null if full). Text over STRING_CAP
    // is truncated by StrBuf.set.
    pub fn addString(s: *Store, text: []const u8) ?u16 {
        if (s.string_count >= MAX_STRINGS) return null;
        const id: u16 = @intCast(s.string_count);
        s.strings[id].set(text);
        s.string_count += 1;
        return id;
    }

    pub fn addSwitch(s: *Store, name: []const u8) ?u16 {
        if (s.switch_count >= MAX_SWITCHES) return null;
        const id: u16 = @intCast(s.switch_count);
        s.switch_names[id].set(name);
        s.switch_count += 1;
        return id;
    }

    pub fn addCounter(s: *Store, name: []const u8) ?u16 {
        if (s.counter_count >= MAX_COUNTERS) return null;
        const id: u16 = @intCast(s.counter_count);
        s.counter_names[id].set(name);
        s.counter_count += 1;
        return id;
    }

    // Append an empty trigger, returning a pointer to it (or null if full).
    pub fn addTrigger(s: *Store, name: []const u8) ?*Trigger {
        if (s.trigger_count >= MAX_TRIGGERS) return null;
        s.triggers[s.trigger_count] = .{};
        const t = &s.triggers[s.trigger_count];
        t.name.set(name);
        s.trigger_count += 1;
        return t;
    }

    // Swap-remove trigger i (mirrors map.swapRemove; runtime fired[] must be reset by the
    // caller, since a swap moves a different trigger into slot i).
    pub fn removeTrigger(s: *Store, i: usize) void {
        std.debug.assert(i < s.trigger_count);
        s.trigger_count -= 1;
        s.triggers[i] = s.triggers[s.trigger_count];
    }

    pub fn stringText(s: *const Store, id: u16) []const u8 {
        return if (id < s.string_count) s.strings[id].slice() else "";
    }
    pub fn switchName(s: *const Store, id: u16) []const u8 {
        return if (id < s.switch_count) s.switch_names[id].slice() else "?";
    }
    pub fn counterName(s: *const Store, id: u16) []const u8 {
        return if (id < s.counter_count) s.counter_names[id].slice() else "?";
    }
};

// ── Runtime state (NOT serialized) ───────────────────────────────────────────────
// Lives on the Game, reset each area/playtest. Holds switch/counter VALUES, which triggers
// have fired, per-NPC talk flags, and the live dialogue box. Authored data (names, scripts)
// stays in Store; the game.zig evaluator reads Store + this and drives player/world effects.
pub const OBJECTIVE_CAP = 96;
pub const MAX_ACTIVE_CHOICES = 6;

pub const Dialogue = struct {
    active: bool = false,
    npc: u16 = 0, // the speaking NPC (index into Map.npcs)
    trigger: u16 = 0, // the trigger whose action script is running
    cursor: usize = 0, // next act index to run when the player advances a `say`
    wait: Wait = .none,
    text: StrBuf(STRING_CAP) = .{}, // the line currently shown (copied from the pool)
    choices: [MAX_ACTIVE_CHOICES]Choice = undefined,
    choice_count: usize = 0,
    sel: usize = 0, // highlighted choice

    pub const Wait = enum { none, advance, choose };
    pub const Choice = struct {
        label: StrBuf(STRING_CAP) = .{},
        jump: usize = 0, // act index of this branch's first action (run when picked)
    };
};

pub const Runtime = struct {
    switches: [MAX_SWITCHES]bool = [_]bool{false} ** MAX_SWITCHES,
    counters: [MAX_COUNTERS]i32 = [_]i32{0} ** MAX_COUNTERS,
    fired: [MAX_TRIGGERS]bool = [_]bool{false} ** MAX_TRIGGERS,
    talked: [RT_MAX_NPCS]bool = [_]bool{false} ** RT_MAX_NPCS,
    elapsed: f32 = 0, // seconds since the area began (the `elapsed` condition)
    evalTimer: f32 = 0, // cadence accumulator for the passive trigger loop
    interactNpc: ?u16 = null, // set for one eval pass when the player talks to an NPC
    dialogue: Dialogue = .{},
    objective: StrBuf(OBJECTIVE_CAP) = .{},
    hasObjective: bool = false,

    pub fn reset(r: *Runtime) void {
        r.* = .{};
    }
};

// Given the index of a `choice` act, return the index just past its matching `end_choice`
// (depth-aware, so a branch may itself hold nested choice groups). Used to walk from one
// sibling choice to the next when gathering a prompt.
pub fn branchEnd(acts: []const Act, choiceIdx: usize) usize {
    var depth: i32 = 0;
    var i = choiceIdx;
    while (i < acts.len) : (i += 1) {
        switch (acts[i]) {
            .choice => depth += 1,
            .end_choice => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return acts.len; // unbalanced authoring: treat as end-of-script
}

// ── Serialization ───────────────────────────────────────────────────────────────
// Lines stay `key: payload`, one record per line, to match map.zig. Pools serialize as
// id-tagged lines emitted in order (id == running count); triggers reference pool ids.
// Names/text are FREE-TEXT tails (may contain spaces) and are read via it.rest().

pub fn saveInto(w: anytype, s: *const Store) !void {
    for (s.strings[0..s.string_count], 0..) |str, i| {
        try w.print("str: {d} {s}\n", .{ i, str.slice() });
    }
    for (s.switch_names[0..s.switch_count], 0..) |nm, i| {
        try w.print("switch: {d} {s}\n", .{ i, nm.slice() });
    }
    for (s.counter_names[0..s.counter_count], 0..) |nm, i| {
        try w.print("counter: {d} {s}\n", .{ i, nm.slice() });
    }
    for (s.triggerList(), 0..) |t, i| {
        try w.print("trig: {d} {s}\n", .{ i, t.name.slice() });
        for (t.condList()) |c| {
            try w.print("tcond: {d} ", .{i});
            try writeCond(w, c);
            try w.writeAll("\n");
        }
        for (t.actList()) |a| {
            try w.print("tact: {d} ", .{i});
            try writeAct(w, a);
            try w.writeAll("\n");
        }
    }
}

fn writeCond(w: anytype, c: Cond) !void {
    switch (c) {
        .always => try w.writeAll("always"),
        .never => try w.writeAll("never"),
        .switch_on => |id| try w.print("switch_on {d}", .{id}),
        .switch_off => |id| try w.print("switch_off {d}", .{id}),
        .counter => |x| try w.print("counter {d} {s} {d}", .{ x.c, @tagName(x.op), x.n }),
        .in_region => |id| try w.print("in_region {d}", .{id}),
        .near_npc => |id| try w.print("near_npc {d}", .{id}),
        .talked_to => |id| try w.print("talked_to {d}", .{id}),
        .on_talk => |id| try w.print("on_talk {d}", .{id}),
        .player_level => |x| try w.print("player_level {s} {d}", .{ @tagName(x.op), x.n }),
        .elapsed => |x| try w.print("elapsed {s} {d:.2}", .{ @tagName(x.op), x.secs }),
    }
}

fn writeAct(w: anytype, a: Act) !void {
    switch (a) {
        .say => |x| try w.print("say {d} {d}", .{ x.npc, x.text }),
        .choice => |id| try w.print("choice {d}", .{id}),
        .end_choice => try w.writeAll("end_choice"),
        .end_dialogue => try w.writeAll("end_dialogue"),
        .message => |id| try w.print("message {d}", .{id}),
        .set_switch => |x| try w.print("set_switch {d} {s}", .{ x.s, @tagName(x.mode) }),
        .set_counter => |x| try w.print("set_counter {d} {s} {d}", .{ x.c, @tagName(x.mode), x.n }),
        .grant_skill => |sk| try w.print("grant_skill {s}", .{@tagName(sk)}),
        .spawn => |x| try w.print("spawn {s} {d} {d}", .{ @tagName(x.kind), x.count, x.region }),
        .teleport => |id| try w.print("teleport {d}", .{id}),
        .center_cam => |id| try w.print("center_cam {d}", .{id}),
        .set_objective => |id| try w.print("set_objective {d}", .{id}),
        .run_trigger => |id| try w.print("run_trigger {d}", .{id}),
        .preserve => try w.writeAll("preserve"),
    }
}

// ── Parsing ─────────────────────────────────────────────────────────────────────
pub const ParseResult = enum { not_mine, handled, bad };

const ParseError = error{Bad};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn pU16(it: *Tok) ParseError!u16 {
    const tok = it.next() orelse return error.Bad;
    return std.fmt.parseInt(u16, tok, 10) catch error.Bad;
}
fn pI32(it: *Tok) ParseError!i32 {
    const tok = it.next() orelse return error.Bad;
    return std.fmt.parseInt(i32, tok, 10) catch error.Bad;
}
fn pF32(it: *Tok) ParseError!f32 {
    const tok = it.next() orelse return error.Bad;
    const v = std.fmt.parseFloat(f32, tok) catch return error.Bad;
    if (!std.math.isFinite(v)) return error.Bad; // an inf/nan seconds would break the tick
    return v;
}
fn pEnum(comptime T: type, it: *Tok) ParseError!T {
    const tok = it.next() orelse return error.Bad;
    return std.meta.stringToEnum(T, tok) orelse error.Bad;
}

fn parseCond(it: *Tok) ParseError!Cond {
    const tag = it.next() orelse return error.Bad;
    if (eql(tag, "always")) return .always;
    if (eql(tag, "never")) return .never;
    if (eql(tag, "switch_on")) return .{ .switch_on = try pU16(it) };
    if (eql(tag, "switch_off")) return .{ .switch_off = try pU16(it) };
    if (eql(tag, "counter")) return .{ .counter = .{ .c = try pU16(it), .op = try pEnum(Op, it), .n = try pI32(it) } };
    if (eql(tag, "in_region")) return .{ .in_region = try pU16(it) };
    if (eql(tag, "near_npc")) return .{ .near_npc = try pU16(it) };
    if (eql(tag, "talked_to")) return .{ .talked_to = try pU16(it) };
    if (eql(tag, "on_talk")) return .{ .on_talk = try pU16(it) };
    if (eql(tag, "player_level")) return .{ .player_level = .{ .op = try pEnum(Op, it), .n = try pI32(it) } };
    if (eql(tag, "elapsed")) return .{ .elapsed = .{ .op = try pEnum(Op, it), .secs = try pF32(it) } };
    return error.Bad;
}

fn parseAct(it: *Tok) ParseError!Act {
    const tag = it.next() orelse return error.Bad;
    if (eql(tag, "say")) return .{ .say = .{ .npc = try pU16(it), .text = try pU16(it) } };
    if (eql(tag, "choice")) return .{ .choice = try pU16(it) };
    if (eql(tag, "end_choice")) return .end_choice;
    if (eql(tag, "end_dialogue")) return .end_dialogue;
    if (eql(tag, "message")) return .{ .message = try pU16(it) };
    if (eql(tag, "set_switch")) return .{ .set_switch = .{ .s = try pU16(it), .mode = try pEnum(SwitchMode, it) } };
    if (eql(tag, "set_counter")) return .{ .set_counter = .{ .c = try pU16(it), .mode = try pEnum(CounterMode, it), .n = try pI32(it) } };
    if (eql(tag, "grant_skill")) return .{ .grant_skill = try pEnum(player.Skill, it) };
    if (eql(tag, "spawn")) return .{ .spawn = .{ .kind = try pEnum(monster.MonsterKind, it), .count = try pI32(it), .region = try pU16(it) } };
    if (eql(tag, "teleport")) return .{ .teleport = try pU16(it) };
    if (eql(tag, "center_cam")) return .{ .center_cam = try pU16(it) };
    if (eql(tag, "set_objective")) return .{ .set_objective = try pU16(it) };
    if (eql(tag, "run_trigger")) return .{ .run_trigger = try pU16(it) };
    if (eql(tag, "preserve")) return .preserve;
    return error.Bad;
}

fn bad(why: []const u8) ParseResult {
    std.debug.print("trigger parse error: {s}\n", .{why});
    return .bad;
}

// One line from map.load. Returns .not_mine (without touching `it`) for keys we don't own,
// so map.zig's own parser can try them; .handled on success; .bad (logged) on a malformed
// line we DO own. Free-text tails (names/text) are read via it.rest(); token lines
// (tcond/tact) are trailing-checked here so map.zig can `continue` past its own check.
pub fn parseLine(s: *Store, key: []const u8, it: *Tok) ParseResult {
    if (eql(key, "str")) {
        const id = pU16(it) catch return bad("str id");
        if (id != s.string_count) return bad("str id out of order");
        if (s.string_count >= MAX_STRINGS) return bad("too many strings");
        s.strings[s.string_count].set(std.mem.trimLeft(u8, it.rest(), " "));
        s.string_count += 1;
        return .handled;
    } else if (eql(key, "switch")) {
        const id = pU16(it) catch return bad("switch id");
        if (id != s.switch_count) return bad("switch id out of order");
        if (s.switch_count >= MAX_SWITCHES) return bad("too many switches");
        s.switch_names[s.switch_count].set(std.mem.trimLeft(u8, it.rest(), " "));
        s.switch_count += 1;
        return .handled;
    } else if (eql(key, "counter")) {
        const id = pU16(it) catch return bad("counter id");
        if (id != s.counter_count) return bad("counter id out of order");
        if (s.counter_count >= MAX_COUNTERS) return bad("too many counters");
        s.counter_names[s.counter_count].set(std.mem.trimLeft(u8, it.rest(), " "));
        s.counter_count += 1;
        return .handled;
    } else if (eql(key, "trig")) {
        const id = pU16(it) catch return bad("trig id");
        if (id != s.trigger_count) return bad("trig id out of order");
        if (s.trigger_count >= MAX_TRIGGERS) return bad("too many triggers");
        s.triggers[s.trigger_count] = .{};
        s.triggers[s.trigger_count].name.set(std.mem.trimLeft(u8, it.rest(), " "));
        s.trigger_count += 1;
        return .handled;
    } else if (eql(key, "tcond")) {
        const tid = pU16(it) catch return bad("tcond id");
        if (tid >= s.trigger_count) return bad("tcond names an unknown trigger");
        const t = &s.triggers[tid];
        if (t.cond_count >= MAX_TRIG_CONDS) return bad("too many conditions");
        const c = parseCond(it) catch return bad("bad condition");
        if (it.next() != null) return bad("trailing data on condition");
        t.conds[t.cond_count] = c;
        t.cond_count += 1;
        return .handled;
    } else if (eql(key, "tact")) {
        const tid = pU16(it) catch return bad("tact id");
        if (tid >= s.trigger_count) return bad("tact names an unknown trigger");
        const t = &s.triggers[tid];
        if (t.act_count >= MAX_TRIG_ACTS) return bad("too many actions");
        const a = parseAct(it) catch return bad("bad action");
        if (it.next() != null) return bad("trailing data on action");
        t.acts[t.act_count] = a;
        t.act_count += 1;
        return .handled;
    }
    return .not_mine;
}

// Clamp indices that were hand-edited past the pools they reference, so a bogus id can't
// index out of bounds at runtime. Called from map.sanitize with the live pool/region/npc
// counts. Out-of-range refs collapse to 0 (a valid-but-wrong slot, never a crash).
pub fn sanitize(s: *Store, region_count: usize, npc_count: usize) void {
    const rc: u16 = @intCast(region_count);
    const nc: u16 = @intCast(npc_count);
    const sc: u16 = @intCast(s.switch_count);
    const cc: u16 = @intCast(s.counter_count);
    const strc: u16 = @intCast(s.string_count);
    const tc: u16 = @intCast(s.trigger_count);
    for (s.triggers[0..s.trigger_count]) |*t| {
        for (t.conds[0..t.cond_count]) |*c| clampCond(c, rc, nc, sc, cc);
        for (t.acts[0..t.act_count]) |*a| clampAct(a, rc, nc, sc, cc, strc, tc);
    }
}

fn clampRef(id: *u16, count: u16) void {
    if (id.* >= count) id.* = 0;
}
fn clampCond(c: *Cond, rc: u16, nc: u16, sc: u16, cc: u16) void {
    switch (c.*) {
        .switch_on, .switch_off => |*id| clampRef(id, sc),
        .counter => |*x| clampRef(&x.c, cc),
        .in_region => |*id| clampRef(id, rc),
        .near_npc, .talked_to, .on_talk => |*id| clampRef(id, nc),
        .always, .never, .player_level, .elapsed => {},
    }
}
fn clampAct(a: *Act, rc: u16, nc: u16, sc: u16, cc: u16, strc: u16, tc: u16) void {
    switch (a.*) {
        .say => |*x| {
            clampRef(&x.npc, nc);
            clampRef(&x.text, strc);
        },
        .choice, .message, .set_objective => |*id| clampRef(id, strc),
        .set_switch => |*x| clampRef(&x.s, sc),
        .set_counter => |*x| clampRef(&x.c, cc),
        .spawn => |*x| clampRef(&x.region, rc),
        .teleport, .center_cam => |*id| clampRef(id, rc),
        .run_trigger => |*id| clampRef(id, tc),
        .end_choice, .end_dialogue, .grant_skill, .preserve => {},
    }
}

// Split a serialized block back into a Store the way map.load does, for the round-trip test.
fn parseAll(s: *Store, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Bad;
        const k = std.mem.trim(u8, line[0..colon], " ");
        const rest = std.mem.trim(u8, line[colon + 1 ..], " ");
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        switch (parseLine(s, k, &it)) {
            .handled => {},
            else => return error.Bad,
        }
    }
}

test "trigger store save→load round-trips (incl. a branching choice)" {
    const t = std.testing;
    var s = Store{};
    const greeting = s.addString("Winter's been cruel, friend.").?;
    const learn = s.addString("Teach me firebolt.").?;
    const bye = s.addString("Maybe later.").?;
    _ = s.addSwitch("MetElder").?;

    const tr = s.addTrigger("Greet the elder").?;
    tr.conds[0] = .{ .near_npc = 0 };
    tr.conds[1] = .{ .switch_off = 0 };
    tr.cond_count = 2;
    // say → two choices, each a bracketed branch.
    tr.acts[0] = .{ .say = .{ .npc = 0, .text = greeting } };
    tr.acts[1] = .{ .choice = learn };
    tr.acts[2] = .{ .grant_skill = .firebolt };
    tr.acts[3] = .{ .set_switch = .{ .s = 0, .mode = .on } };
    tr.acts[4] = .end_choice;
    tr.acts[5] = .{ .choice = bye };
    tr.acts[6] = .end_dialogue;
    tr.acts[7] = .end_choice;
    tr.acts[8] = .preserve;
    tr.act_count = 9;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try saveInto(fbs.writer(), &s);

    var s2 = Store{};
    try parseAll(&s2, fbs.getWritten());

    try t.expectEqual(s.string_count, s2.string_count);
    try t.expectEqualStrings(s.stringText(greeting), s2.stringText(greeting));
    try t.expectEqualStrings("MetElder", s2.switchName(0));
    try t.expectEqual(@as(usize, 1), s2.trigger_count);
    const r = &s2.triggers[0];
    try t.expectEqualStrings("Greet the elder", r.name.slice());
    try t.expectEqual(@as(usize, 2), r.cond_count);
    try t.expectEqual(@as(usize, 9), r.act_count);
    try t.expect(r.conds[0] == .near_npc);
    try t.expect(r.acts[1] == .choice);
    try t.expect(r.acts[2] == .grant_skill);
    try t.expect(r.acts[2].grant_skill == .firebolt);
    try t.expect(r.acts[8] == .preserve);
}
