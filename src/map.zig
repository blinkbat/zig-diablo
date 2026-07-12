const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");
const monster = @import("monster.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;

// MAP — the authored level format (no procgen; the campaign is maps/*.map in
// lexicographic order, e.g. `01_blood_moor.map`). Line-based text, one object per
// line, diff-friendly and hand-editable, with a required `version:` header. Every
// line is `key: payload`; unknown keys are an ERROR (typos must not silently drop
// half a map). `#` starts a comment.
//
//   version: 2
//   name: The Blood Moor
//   boss: Bishibosh
//   size: 38 30                          (arena half-extents: width depth;
//                                         legacy v1 "half: 38" loads as square)
//   ground: 92 80 62
//   accent: 72 62 50
//   light: 1.04 0.94 0.80
//   spawn: 0 32
//   portal: 0 -31
//   bossat: 2.5 -24
//   ledge: 26 4 36.6 30 2.4              (minX minZ maxX maxZ height)
//   ramp: 20.5 24 26 29.5 2.4 xpos       (rect + height + rise direction)
//   ob: rock 12.5 -3.2 1.42 1.9          (kind x z radius height)
//   decor: tuft 3.1 4.2 0.5              (kind x z size)
//   pack: fallen 3 -10.5 12              (kind count x z)
//
// Tints are NOT stored: colors derive deterministically from the palette + a
// position hash (same look every load).

pub const FORMAT_VERSION = 2; // v2: rectangular arenas (size: W D); v1 'half:' still loads
pub const MAX_PACKS = 24;
pub const MAX_MAPS = 16;
pub const ext = ".map";
pub const dir = "maps";
// Stored map-file path capacity, shared by the campaign list, cached paths, and the
// editor's Ctrl+S target so none silently truncates.
pub const PATH_CAP = 96;

// Default moor palette, shared by Map field defaults and the editor's "Moor" preset
// so a fresh map and the preset can't drift.
pub const DEFAULT_GROUND = rgba(92, 80, 62, 255);
pub const DEFAULT_ACCENT = rgba(72, 62, 50, 255);

const alloc = std.heap.c_allocator;

fn StrBuf(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = [_]u8{0} ** cap,
        len: usize = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Pack = struct {
    kind: monster.MonsterKind = .fallen,
    count: i32 = 3,
    x: f32 = 0,
    z: f32 = 0,

    // Ground position as a Vector3 (y=0). One accessor so callers stop rebuilding
    // `v3(pk.x, 0, pk.z)` by hand (obstacles/decor already carry a `.Pos`).
    pub fn pos(p: Pack) rl.Vector3 {
        return v3(p.x, 0, p.z);
    }
};

pub const Map = struct {
    name: StrBuf(48) = .{},
    boss: StrBuf(monster.NAME_CAP) = .{}, // copied into Monster.nameBuf; caps must match
    halfW: f32 = 30,
    halfD: f32 = 30,
    ground: rl.Color = DEFAULT_GROUND,
    accent: rl.Color = DEFAULT_ACCENT,
    light: [3]f32 = .{ 1.0, 0.95, 0.85 },
    spawn: rl.Vector3 = v3(0, 0, 24),
    portal: rl.Vector3 = v3(0, 0, -23),
    bossPos: rl.Vector3 = v3(0, 0, -18),
    ledges: [world.MAX_LEDGES]world.Ledge = undefined,
    ledge_count: usize = 0,
    ramps: [world.MAX_RAMPS]world.Ramp = undefined,
    ramp_count: usize = 0,
    obstacles: [world.MAX_OBSTACLES]world.Obstacle = undefined,
    obstacle_count: usize = 0,
    decor: [world.MAX_DECOR]world.Decor = undefined,
    decor_count: usize = 0,
    packs: [MAX_PACKS]Pack = undefined,
    pack_count: usize = 0,

    pub fn packList(self: *const Map) []const Pack {
        return self.packs[0..self.pack_count];
    }

    // Swap-remove helpers, one idiom for the editor's many delete sites. See swapRemove
    // below for the shared body (and the live-index contract).
    pub fn removeObstacle(self: *Map, i: usize) void {
        swapRemove(self.obstacles[0..], &self.obstacle_count, i);
    }
    pub fn removeDecor(self: *Map, i: usize) void {
        swapRemove(self.decor[0..], &self.decor_count, i);
    }
    pub fn removePack(self: *Map, i: usize) void {
        swapRemove(self.packs[0..], &self.pack_count, i);
    }
    pub fn removeLedge(self: *Map, i: usize) void {
        swapRemove(self.ledges[0..], &self.ledge_count, i);
    }
    pub fn removeRamp(self: *Map, i: usize) void {
        swapRemove(self.ramps[0..], &self.ramp_count, i);
    }
};

// Swap the last live element into slot `i` and shrink the count — one body for all
// five remove* helpers, so a sixth collection can't forget the guard. `i` MUST be a
// live index: on an empty collection `count -= 1` wraps (usize) into a wild
// out-of-bounds swap in ReleaseFast (where the assert is compiled out), so assert it.
fn swapRemove(arr: anytype, count: *usize, i: usize) void {
    std.debug.assert(i < count.*);
    count.* -= 1;
    arr[i] = arr[count.*];
}

// Inset of the fixed anchors from the arena walls on a fresh map; shared by
// defaultMap and the editor's New Map so they can't drift.
pub const SPAWN_INSET = 6.0;
pub const PORTAL_INSET = 7.0;
pub const BOSS_INSET = 12.0;

/// Fallback world when no map file exists or one fails to parse: a small empty
/// field with spawn, portal, and one pack, so the game always runs.
pub fn defaultMap() Map {
    var m = Map{};
    m.name.set("Empty Field");
    m.boss.set("The Absence");
    // Anchors from the INSET constants (like the editor's New Map), not literals, so
    // retuning an inset or the default half-extent carries through.
    m.spawn = v3(0, 0, m.halfD - SPAWN_INSET);
    m.portal = v3(0, 0, -(m.halfD - PORTAL_INSET));
    m.bossPos = v3(0, 0, -(m.halfD - BOSS_INSET));
    m.packs[0] = .{ .kind = .fallen, .count = 3, .x = 0, .z = 0 };
    m.pack_count = 1;
    return m;
}

// Deterministic per-position variation: the same map renders identically every load.
fn hash01(x: f32, z: f32, salt: f32) f32 {
    const s = @sin(x * 127.1 + z * 311.7 + salt * 74.7) * 43758.5453;
    return s - @floor(s);
}

/// Author-time variation (0..1) for stamping placed objects' sizes in the editor.
pub fn hashAt(x: f32, z: f32) f32 {
    return hash01(x, z, 7);
}

fn obstacleTint(m: *const Map, kind: world.ObstacleKind, x: f32, z: f32) rl.Color {
    return switch (kind) {
        .tree => lerpColor(m.accent, rgba(40, 70, 36, 255), 0.6),
        .gravestone => lerpColor(rgba(86, 88, 98, 255), m.accent, 0.2 + hash01(x, z, 1) * 0.2),
        .rock => lerpColor(m.accent, rgba(90, 90, 96, 255), 0.5),
    };
}

fn decorTint(m: *const Map, kind: world.DecorKind, x: f32, z: f32) rl.Color {
    return switch (kind) {
        .pebble => lerpColor(m.accent, rgba(140, 138, 132, 255), 0.3 + hash01(x, z, 2) * 0.4),
        .tuft => lerpColor(m.ground, rgba(105, 140, 70, 255), 0.4 + hash01(x, z, 3) * 0.3),
        .shroom => if (hash01(x, z, 4) < 0.5) rgba(214, 168, 96, 255) else rgba(190, 120, 130, 255),
        .bone => lerpColor(rgba(212, 205, 185, 255), m.ground, 0.15 + hash01(x, z, 5) * 0.15),
    };
}

/// Materialize the static world this map describes. The World carries no strings
/// (names are read from Game.map at display time; a slice into a by-value World
/// would dangle when the source struct moves).
pub fn toWorld(m: *const Map, isLast: bool) world.World {
    var w = world.World{
        .HalfW = m.halfW,
        .HalfD = m.halfD,
        .Ground = m.ground,
        .Accent = m.accent,
        .PortalPos = v3(m.portal.x, 0, m.portal.z),
        .IsLast = isLast,
    };
    w.ledge_count = m.ledge_count;
    for (m.ledges[0..m.ledge_count], 0..) |l, i| w.ledges[i] = l;
    w.ramp_count = m.ramp_count;
    for (m.ramps[0..m.ramp_count], 0..) |r, i| w.ramps[i] = r;
    w.obstacle_count = m.obstacle_count;
    for (m.obstacles[0..m.obstacle_count], 0..) |o, i| {
        w.obstacles[i] = o;
        w.obstacles[i].Tint = obstacleTint(m, o.Kind, o.Pos.x, o.Pos.z);
        // Props stand ON the terrain: bake at the local ground height (ledges/ramps
        // copied above, so groundY is live).
        w.obstacles[i].Pos.y = w.groundY(o.Pos.x, o.Pos.z);
    }
    w.decor_count = m.decor_count;
    for (m.decor[0..m.decor_count], 0..) |d, i| {
        w.decor[i] = d;
        w.decor[i].Tint = decorTint(m, d.Kind, d.Pos.x, d.Pos.z);
        w.decor[i].Pos.y = w.groundY(d.Pos.x, d.Pos.z);
    }
    return w;
}

// ---- Saving ----

pub fn save(m: *const Map, path: []const u8) !void {
    std.fs.cwd().makePath(dir) catch {};
    // Keep a .bak of whatever was there before, so we never clobber the only copy.
    var bakBuf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&bakBuf, "{s}.bak", .{path})) |bak| {
        std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{}) catch {};
    } else |_| {}

    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    const w = f.writer();
    try w.print("version: {d}\n", .{FORMAT_VERSION});
    try w.print("name: {s}\n", .{m.name.slice()});
    try w.print("boss: {s}\n", .{m.boss.slice()});
    try w.print("size: {d:.1} {d:.1}\n", .{ m.halfW, m.halfD });
    try w.print("ground: {d} {d} {d}\n", .{ m.ground.r, m.ground.g, m.ground.b });
    try w.print("accent: {d} {d} {d}\n", .{ m.accent.r, m.accent.g, m.accent.b });
    try w.print("light: {d:.2} {d:.2} {d:.2}\n", .{ m.light[0], m.light[1], m.light[2] });
    try w.print("spawn: {d:.1} {d:.1}\n", .{ m.spawn.x, m.spawn.z });
    try w.print("portal: {d:.1} {d:.1}\n", .{ m.portal.x, m.portal.z });
    try w.print("bossat: {d:.1} {d:.1}\n", .{ m.bossPos.x, m.bossPos.z });
    for (m.ledges[0..m.ledge_count]) |l| {
        try w.print("ledge: {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}\n", .{ l.minX, l.minZ, l.maxX, l.maxZ, l.h });
    }
    for (m.ramps[0..m.ramp_count]) |r| {
        try w.print("ramp: {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {s}\n", .{ r.minX, r.minZ, r.maxX, r.maxZ, r.h, @tagName(r.rise) });
    }
    for (m.obstacles[0..m.obstacle_count]) |o| {
        try w.print("ob: {s} {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ @tagName(o.Kind), o.Pos.x, o.Pos.z, o.Radius, o.Height });
    }
    for (m.decor[0..m.decor_count]) |d| {
        try w.print("decor: {s} {d:.2} {d:.2} {d:.2}\n", .{ @tagName(d.Kind), d.Pos.x, d.Pos.z, d.Size });
    }
    for (m.packs[0..m.pack_count]) |p| {
        try w.print("pack: {s} {d} {d:.1} {d:.1}\n", .{ @tagName(p.kind), p.count, p.x, p.z });
    }
}

// ---- Loading ----

// Every malformed-line case routes through fail() -> BadLine with a descriptive log;
// callers fall back to defaultMap regardless, so one variant covers them all.
const LoadError = error{ BadHeader, BadLine, ReadFailed };

fn fail(lineNo: usize, line: []const u8, why: []const u8) LoadError {
    std.debug.print("map load error, line {d}: {s} -- \"{s}\"\n", .{ lineNo, why, line });
    return LoadError.BadLine;
}

fn nextF32(it: *std.mem.TokenIterator(u8, .scalar)) !f32 {
    const tok = it.next() orelse return LoadError.BadLine;
    const val = std.fmt.parseFloat(f32, tok) catch return LoadError.BadLine;
    // parseFloat accepts "inf"/"nan"; a non-finite coord would detonate later
    // (hash01(@sin(inf))->NaN->@intFromFloat). Reject so every stored float is finite.
    if (!std.math.isFinite(val)) return LoadError.BadLine;
    return val;
}

fn nextU8(it: *std.mem.TokenIterator(u8, .scalar)) !u8 {
    const tok = it.next() orelse return LoadError.BadLine;
    return std.fmt.parseInt(u8, tok, 10) catch LoadError.BadLine;
}

fn nextEnum(comptime T: type, it: *std.mem.TokenIterator(u8, .scalar)) !T {
    const tok = it.next() orelse return LoadError.BadLine;
    return std.meta.stringToEnum(T, tok) orelse LoadError.BadLine;
}

pub fn load(path: []const u8) LoadError!Map {
    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return LoadError.ReadFailed;
    defer alloc.free(data);

    var m = Map{};
    var sawVersion = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var lineNo: usize = 0;
    while (lines.next()) |raw| {
        lineNo += 1;
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return fail(lineNo, line, "missing ':'");
        const key = std.mem.trim(u8, line[0..colon], " ");
        const rest = std.mem.trim(u8, line[colon + 1 ..], " ");
        var it = std.mem.tokenizeScalar(u8, rest, ' ');

        if (std.mem.eql(u8, key, "version")) {
            const ver = nextF32(&it) catch return fail(lineNo, line, "bad version");
            // Compare as float (never @intFromFloat an unvalidated parse — huge/inf/NaN
            // makes the cast illegal). Require 1 <= ver <= FORMAT_VERSION: the negated,
            // range-checked form also rejects NaN, and the lower bound rejects a
            // truncated/typo'd value (0, negative) that would otherwise load silently.
            if (!(ver >= 1 and ver <= @as(f32, @floatFromInt(FORMAT_VERSION)))) return fail(lineNo, line, "unsupported map format version");
            sawVersion = true;
        } else if (std.mem.eql(u8, key, "name")) {
            m.name.set(rest);
        } else if (std.mem.eql(u8, key, "boss")) {
            m.boss.set(rest);
        } else if (std.mem.eql(u8, key, "size")) {
            m.halfW = nextF32(&it) catch return fail(lineNo, line, "bad size");
            m.halfD = nextF32(&it) catch return fail(lineNo, line, "bad size");
        } else if (std.mem.eql(u8, key, "half")) {
            // Legacy v1 square arena: one extent for both axes.
            m.halfW = nextF32(&it) catch return fail(lineNo, line, "bad half");
            m.halfD = m.halfW;
        } else if (std.mem.eql(u8, key, "ground")) {
            m.ground = rgba(nextU8(&it) catch return fail(lineNo, line, "bad ground"), nextU8(&it) catch return fail(lineNo, line, "bad ground"), nextU8(&it) catch return fail(lineNo, line, "bad ground"), 255);
        } else if (std.mem.eql(u8, key, "accent")) {
            m.accent = rgba(nextU8(&it) catch return fail(lineNo, line, "bad accent"), nextU8(&it) catch return fail(lineNo, line, "bad accent"), nextU8(&it) catch return fail(lineNo, line, "bad accent"), 255);
        } else if (std.mem.eql(u8, key, "light")) {
            for (0..3) |i| m.light[i] = nextF32(&it) catch return fail(lineNo, line, "bad light");
        } else if (std.mem.eql(u8, key, "spawn")) {
            m.spawn = v3(nextF32(&it) catch return fail(lineNo, line, "bad spawn"), 0, nextF32(&it) catch return fail(lineNo, line, "bad spawn"));
        } else if (std.mem.eql(u8, key, "portal")) {
            m.portal = v3(nextF32(&it) catch return fail(lineNo, line, "bad portal"), 0, nextF32(&it) catch return fail(lineNo, line, "bad portal"));
        } else if (std.mem.eql(u8, key, "bossat")) {
            m.bossPos = v3(nextF32(&it) catch return fail(lineNo, line, "bad bossat"), 0, nextF32(&it) catch return fail(lineNo, line, "bad bossat"));
        } else if (std.mem.eql(u8, key, "ledge")) {
            if (m.ledge_count >= world.MAX_LEDGES) return fail(lineNo, line, "too many ledges");
            m.ledges[m.ledge_count] = .{
                .minX = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .minZ = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .maxX = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .maxZ = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .h = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
            };
            m.ledge_count += 1;
        } else if (std.mem.eql(u8, key, "ramp")) {
            if (m.ramp_count >= world.MAX_RAMPS) return fail(lineNo, line, "too many ramps");
            m.ramps[m.ramp_count] = .{
                .minX = nextF32(&it) catch return fail(lineNo, line, "bad ramp"),
                .minZ = nextF32(&it) catch return fail(lineNo, line, "bad ramp"),
                .maxX = nextF32(&it) catch return fail(lineNo, line, "bad ramp"),
                .maxZ = nextF32(&it) catch return fail(lineNo, line, "bad ramp"),
                .h = nextF32(&it) catch return fail(lineNo, line, "bad ramp"),
                .rise = nextEnum(world.RampRise, &it) catch return fail(lineNo, line, "bad ramp rise"),
            };
            m.ramp_count += 1;
        } else if (std.mem.eql(u8, key, "ob")) {
            if (m.obstacle_count >= world.MAX_OBSTACLES) return fail(lineNo, line, "too many obstacles");
            const kind = nextEnum(world.ObstacleKind, &it) catch return fail(lineNo, line, "bad obstacle kind");
            m.obstacles[m.obstacle_count] = .{
                .Kind = kind,
                .Pos = v3(nextF32(&it) catch return fail(lineNo, line, "bad ob"), 0, nextF32(&it) catch return fail(lineNo, line, "bad ob")),
                .Radius = nextF32(&it) catch return fail(lineNo, line, "bad ob"),
                .Height = nextF32(&it) catch return fail(lineNo, line, "bad ob"),
            };
            m.obstacle_count += 1;
        } else if (std.mem.eql(u8, key, "decor")) {
            if (m.decor_count >= world.MAX_DECOR) return fail(lineNo, line, "too many decor");
            const kind = nextEnum(world.DecorKind, &it) catch return fail(lineNo, line, "bad decor kind");
            m.decor[m.decor_count] = .{
                .Kind = kind,
                .Pos = v3(nextF32(&it) catch return fail(lineNo, line, "bad decor"), 0, nextF32(&it) catch return fail(lineNo, line, "bad decor")),
                .Size = nextF32(&it) catch return fail(lineNo, line, "bad decor"),
            };
            m.decor_count += 1;
        } else if (std.mem.eql(u8, key, "pack")) {
            if (m.pack_count >= MAX_PACKS) return fail(lineNo, line, "too many packs");
            const kind = nextEnum(monster.MonsterKind, &it) catch return fail(lineNo, line, "bad pack kind");
            const count = it.next() orelse return fail(lineNo, line, "bad pack");
            m.packs[m.pack_count] = .{
                .kind = kind,
                .count = std.fmt.parseInt(i32, count, 10) catch return fail(lineNo, line, "bad pack count"),
                .x = nextF32(&it) catch return fail(lineNo, line, "bad pack"),
                .z = nextF32(&it) catch return fail(lineNo, line, "bad pack"),
            };
            m.pack_count += 1;
        } else {
            return fail(lineNo, line, "unknown key");
        }
        // Leftover tokens mean a typo'd/merge-mangled line — reject loudly, as with
        // unknown keys. `name`/`boss` hold free text and never consume their tokens.
        if (!std.mem.eql(u8, key, "name") and !std.mem.eql(u8, key, "boss") and it.next() != null) {
            return fail(lineNo, line, "trailing data");
        }
    }
    if (!sawVersion) {
        std.debug.print("map load error: {s} has no 'version:' header\n", .{path});
        return LoadError.BadHeader;
    }
    sanitize(&m);
    return m;
}

// Ledge and Ramp share the minX/maxX/minZ/maxZ/h rect fields; sanitize both the same
// way — un-invert the rect, clamp it to the arena walls, clamp the height — so the two
// feature paths can't drift. `f` is a pointer to a Ledge or Ramp.
fn sanitizeFeatureRect(f: anytype, hw: f32, hd: f32) void {
    if (f.minX > f.maxX) std.mem.swap(f32, &f.minX, &f.maxX);
    if (f.minZ > f.maxZ) std.mem.swap(f32, &f.minZ, &f.maxZ);
    f.minX = std.math.clamp(f.minX, -hw, hw);
    f.maxX = std.math.clamp(f.maxX, -hw, hw);
    f.minZ = std.math.clamp(f.minZ, -hd, hd);
    f.maxZ = std.math.clamp(f.maxZ, -hd, hd);
    f.h = std.math.clamp(f.h, 0.4, 8);
}

// Harden a parsed map against hand-edited nonsense: zero-size arenas, inverted
// feature rects, empty pack counts (a pack of 0 divides by zero in the tick ring).
fn sanitize(m: *Map) void {
    m.halfW = std.math.clamp(m.halfW, 12, 60);
    m.halfD = std.math.clamp(m.halfD, 12, 60);
    if (m.name.len == 0) m.name.set("Unnamed");
    if (m.boss.len == 0) m.boss.set("Champion");
    // Clamp every stored coordinate to the arena walls. nextF32 rejected inf/NaN, but
    // a finite-but-HUGE value (e.g. `ledge: 1e18`) would still crash an @intFromFloat
    // in the editor minimap and place content in the void. No-op for in-arena maps.
    const hw = m.halfW;
    const hd = m.halfD;
    m.spawn = v3(std.math.clamp(m.spawn.x, -hw, hw), 0, std.math.clamp(m.spawn.z, -hd, hd));
    m.portal = v3(std.math.clamp(m.portal.x, -hw, hw), 0, std.math.clamp(m.portal.z, -hd, hd));
    m.bossPos = v3(std.math.clamp(m.bossPos.x, -hw, hw), 0, std.math.clamp(m.bossPos.z, -hd, hd));
    // Sizes/heights/light clamped like coordinates: wider than the editor authors
    // (hand edits stay welcome), but a finite-but-HUGE value can't reach the renderer
    // (a 1e18 ledge height would put the hero/camera/shadow rig in orbit).
    for (&m.light) |*c| c.* = std.math.clamp(c.*, 0, 4);
    for (m.ledges[0..m.ledge_count]) |*l| sanitizeFeatureRect(l, hw, hd);
    for (m.ramps[0..m.ramp_count]) |*r| sanitizeFeatureRect(r, hw, hd);
    for (m.obstacles[0..m.obstacle_count]) |*o| {
        o.Pos.x = std.math.clamp(o.Pos.x, -hw, hw);
        o.Pos.z = std.math.clamp(o.Pos.z, -hd, hd);
        o.Radius = std.math.clamp(o.Radius, 0.2, 6);
        o.Height = std.math.clamp(o.Height, 0.3, 12);
    }
    for (m.decor[0..m.decor_count]) |*d| {
        d.Pos.x = std.math.clamp(d.Pos.x, -hw, hw);
        d.Pos.z = std.math.clamp(d.Pos.z, -hd, hd);
        d.Size = std.math.clamp(d.Size, 0.02, 3);
    }
    for (m.packs[0..m.pack_count]) |*p| {
        p.count = std.math.clamp(p.count, 1, 16);
        p.x = std.math.clamp(p.x, -hw, hw);
        p.z = std.math.clamp(p.z, -hd, hd);
    }
}

/// The campaign: every maps/*.map, lexicographically ordered (name files 01_xxx.map,
/// 02_xxx.map ...). Returns how many were found.
pub fn listCampaign(paths: *[MAX_MAPS][PATH_CAP]u8, lens: *[MAX_MAPS]usize) usize {
    var n: usize = 0;
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return 0;
    defer d.close();
    var it = d.iterate();
    // A mid-scan readdir error must still fall through to the sort: campaign order is
    // load-bearing (difficulty tier = areaIndex; IsLast/victory key off the sorted
    // index), so stop collecting, keep what we have, and sort. (`break` can't live in
    // the while-condition, so drive the iterator explicitly.)
    while (true) {
        const entry = (it.next() catch break) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        if (n >= MAX_MAPS) break;
        const full = std.fmt.bufPrint(&paths[n], "{s}/{s}", .{ dir, entry.name }) catch continue;
        lens[n] = full.len;
        n += 1;
    }
    // Lexicographic insertion sort (n is tiny).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, paths[j][0..lens[j]], paths[j - 1][0..lens[j - 1]]) == .lt) : (j -= 1) {
            std.mem.swap([PATH_CAP]u8, &paths[j], &paths[j - 1]);
            std.mem.swap(usize, &lens[j], &lens[j - 1]);
        }
    }
    return n;
}
