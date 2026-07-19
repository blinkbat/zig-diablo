const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");
const monster = @import("monster.zig");
const torchlight = @import("torchlight.zig");
const trigger = @import("trigger.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;

// MAP — the authored level format (no procgen; the campaign is maps/*.map in
// lexicographic order, e.g. `01_blood_moor.map`). Line-based text, one object per
// line, diff-friendly and hand-editable, with a required `version:` header. Every
// line is `key: payload`; unknown keys are an ERROR (typos must not silently drop
// half a map). A line beginning with `#` is a comment (whole-line only — a `#` after
// a payload is NOT stripped and will fail the trailing-data check).
//
//   version: 3
//   name: The Blood Moor
//   boss: Bishibosh
//   size: 38 30                          (arena half-extents: width depth;
//                                         legacy v1 "half: 38" loads as square)
//   floor: grass dirt mud                (floor materials: primary secondary tertiary;
//                                         see world.FloorMat. Replaces the old v1/v2
//                                         ground/accent palette, which still parses
//                                         but is discarded)
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
// Tints are NOT stored: colors derive deterministically from fixed environment tones
// + a position hash (same look every load); the GROUND look is entirely the floor
// materials, painted procedurally in the scene shader.

pub const FORMAT_VERSION = 4; // v4: paintable floor grid (floorbase/fm) replaces the floor set; v1-v3 still load
pub const MAX_PACKS = 64;
pub const MAX_REGIONS = 24; // named rectangles (StarEdit "Locations") triggers key off
pub const MAX_NPCS = 24; // placed townsfolk the conversation triggers address
pub const MAX_MAPS = 32;
// Load-time clamps (see sanitize). Deliberately WIDER than the editor's steppers so
// hand-edited/legacy maps stay welcome; the editor curates a tighter authoring range.
pub const HALF_MIN = 12;
pub const HALF_MAX = 128;
pub const PACK_MEMBERS_MIN = 1;
pub const PACK_MEMBERS_MAX = 32;
pub const ext = ".map";
pub const bak_ext = ".bak"; // suffix of the pre-save backup copy
pub const dir = "maps";
// Stored map-file path capacity, shared by the campaign list, cached paths, and the
// editor's Ctrl+S target so none silently truncates.
pub const PATH_CAP = 96;

// Default moor floor set, shared by Map field defaults and the editor's "Moor"
// preset so a fresh map and the preset can't drift.
pub const DEFAULT_FLOOR: world.FloorSet = .{ .grass, .dirt, .mud };

const alloc = std.heap.c_allocator;

const StrBuf = mathx.StrBuf; // fixed-capacity inline string, shared with Monster

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

pub const REGION_NAME_CAP = 28;
pub const NPC_NAME_CAP = 28;

// A named rectangle on the ground plane — StarEdit's "Location". Triggers test whether the
// hero is inside one, and actions spawn/teleport/center relative to one.
pub const Region = struct {
    name: StrBuf(REGION_NAME_CAP) = .{},
    minX: f32 = 0,
    minZ: f32 = 0,
    maxX: f32 = 0,
    maxZ: f32 = 0,

    pub fn cx(r: Region) f32 {
        return (r.minX + r.maxX) / 2;
    }
    pub fn cz(r: Region) f32 {
        return (r.minZ + r.maxZ) / 2;
    }
    pub fn center(r: Region) rl.Vector3 {
        return v3(r.cx(), 0, r.cz());
    }
    pub fn contains(r: Region, x: f32, z: f32) bool {
        return world.inRect(r.minX, r.maxX, r.minZ, r.maxZ, x, z);
    }
};

// Portrait/body archetype for a townsperson; drives the drawn body tint and the dialogue
// portrait. Extend freely (add to the editor's NPC brush list to place a new kind).
pub const NpcKind = enum(u8) { villager, elder, merchant, guard, blacksmith, wizard };

// A placed, non-combat townsperson. Not a Monster: it never fights, and the player TALKS to
// it (an interact fires the trigger(s) whose conditions name this NPC).
pub const Npc = struct {
    name: StrBuf(NPC_NAME_CAP) = .{},
    kind: NpcKind = .villager,
    x: f32 = 0,
    z: f32 = 0,
    facing: f32 = 0, // heading in degrees (0 = -Z, matching the hero's default facing)

    pub fn pos(n: Npc) rl.Vector3 {
        return v3(n.x, 0, n.z);
    }
};

pub const MAP_NAME_CAP = 48; // display-name cap; independent of monster.NAME_CAP (boss name)

// Fresh-map arena half-extents; the anchor defaults below derive from this + the
// INSET constants so a map file omitting spawn:/portal:/bossat: lands them exactly
// where defaultMap() and the editor's New Map do.
pub const DEFAULT_HALF: f32 = 30;

pub const Map = struct {
    name: StrBuf(MAP_NAME_CAP) = .{},
    boss: StrBuf(monster.NAME_CAP) = .{}, // copied into Monster.name; caps must match
    halfW: f32 = DEFAULT_HALF,
    halfD: f32 = DEFAULT_HALF,
    // Ground: a per-cell material grid painted in the editor (replaces the old 3-material
    // "theme" blend). floorBase fills fresh/erased cells and drives the decor-tint & minimap
    // tone. Row-major [z*FLOOR_RES + x] over the arena. See world.FLOOR_RES.
    floorGrid: [world.FLOOR_RES * world.FLOOR_RES]u8 = [_]u8{@intFromEnum(world.FloorMat.grass)} ** (world.FLOOR_RES * world.FLOOR_RES),
    floorBase: world.FloorMat = .grass,
    light: [3]f32 = torchlight.DEFAULT_LIGHT,
    spawn: rl.Vector3 = v3(0, 0, DEFAULT_HALF - SPAWN_INSET),
    portal: rl.Vector3 = v3(0, 0, -(DEFAULT_HALF - PORTAL_INSET)),
    bossPos: rl.Vector3 = v3(0, 0, -(DEFAULT_HALF - BOSS_INSET)),
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
    regions: [MAX_REGIONS]Region = undefined,
    region_count: usize = 0,
    npcs: [MAX_NPCS]Npc = undefined,
    npc_count: usize = 0,
    // Authored town/quest logic (triggers, switches, counters, dialogue strings). Embedded
    // by value — all fixed arrays — so the editor's whole-Map undo + live-preview cover it.
    trig: trigger.Store = .{},

    pub fn packList(self: *const Map) []const Pack {
        return self.packs[0..self.pack_count];
    }
    pub fn regionList(self: *const Map) []const Region {
        return self.regions[0..self.region_count];
    }
    pub fn npcList(self: *const Map) []const Npc {
        return self.npcs[0..self.npc_count];
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
    pub fn removeRegion(self: *Map, i: usize) void {
        swapRemove(self.regions[0..], &self.region_count, i);
    }
    pub fn removeNpc(self: *Map, i: usize) void {
        swapRemove(self.npcs[0..], &self.npc_count, i);
    }

    // Fill the whole floor grid with one material (New Map / clear).
    pub fn floorFill(self: *Map, mat: world.FloorMat) void {
        @memset(self.floorGrid[0..], @intFromEnum(mat));
    }

    // Paint every floor cell within `radius` world-units of (x,z) to `mat`. Returns whether any
    // cell changed, so the editor banks undo + re-uploads only on a real edit.
    pub fn floorPaint(self: *Map, x: f32, z: f32, radius: f32, mat: world.FloorMat) bool {
        const id = @intFromEnum(mat);
        const resf: f32 = world.FLOOR_RES;
        const cellW = (2 * self.halfW) / resf;
        const cellD = (2 * self.halfD) / resf;
        const r2 = radius * radius;
        var changed = false;
        var czi: usize = 0;
        while (czi < world.FLOOR_RES) : (czi += 1) {
            const cz = -self.halfD + (@as(f32, @floatFromInt(czi)) + 0.5) * cellD;
            if (@abs(cz - z) > radius) continue;
            var cxi: usize = 0;
            while (cxi < world.FLOOR_RES) : (cxi += 1) {
                const cx = -self.halfW + (@as(f32, @floatFromInt(cxi)) + 0.5) * cellW;
                const dx = cx - x;
                const dz = cz - z;
                if (dx * dx + dz * dz > r2) continue;
                const idx = czi * world.FLOOR_RES + cxi;
                if (self.floorGrid[idx] != id) {
                    self.floorGrid[idx] = id;
                    changed = true;
                }
            }
        }
        return changed;
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
    var m = Map{}; // anchors already seeded from DEFAULT_HALF + the INSET constants
    m.name.set("Empty Field");
    m.boss.set("The Absence");
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

// Prop/decor tints: fixed creepy-moor tones hash-varied by position (the per-map
// palette is gone; area identity comes from the floor materials + light color).
// Organic decor keys off the PRIMARY floor material's base tone so grass reads as
// part of its ground.
fn obstacleTint(m: *const Map, kind: world.ObstacleKind, x: f32, z: f32) rl.Color {
    _ = m;
    return switch (kind) {
        .tree => lerpColor(rgba(56, 48, 38, 255), rgba(38, 52, 32, 255), hash01(x, z, 1)),
        .gravestone => lerpColor(rgba(86, 88, 98, 255), rgba(52, 54, 48, 255), 0.2 + hash01(x, z, 1) * 0.3),
        .rock => lerpColor(rgba(74, 72, 64, 255), rgba(52, 50, 46, 255), hash01(x, z, 1)),
    };
}

fn decorTint(m: *const Map, kind: world.DecorKind, x: f32, z: f32) rl.Color {
    const groundTone = world.FloorMat.base(m.floorBase);
    return switch (kind) {
        .pebble => lerpColor(rgba(96, 92, 84, 255), rgba(66, 62, 56, 255), hash01(x, z, 2)),
        .tuft => lerpColor(groundTone, rgba(105, 140, 70, 255), 0.4 + hash01(x, z, 3) * 0.3),
        .shroom => if (hash01(x, z, 4) < 0.5) rgba(214, 168, 96, 255) else rgba(190, 120, 130, 255),
        .bone => lerpColor(rgba(212, 205, 185, 255), groundTone, 0.15 + hash01(x, z, 5) * 0.15),
        // Rot tones for the oversized fungus: corpse-pale, gangrene-green, liver-brown.
        .bigshroom => switch (@as(u8, @intFromFloat(hash01(x, z, 6) * 2.999))) {
            0 => rgba(150, 140, 118, 255),
            1 => rgba(112, 120, 86, 255),
            else => rgba(96, 74, 56, 255),
        },
    };
}

/// Materialize the static world this map describes. The World carries no strings
/// (names are read from Game.map at display time; a slice into a by-value World
/// would dangle when the source struct moves).
pub fn toWorld(m: *const Map, isLast: bool) world.World {
    var w = world.World{
        .HalfW = m.halfW,
        .HalfD = m.halfD,
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

// Line keys — one spelling per field, shared by save() and load() so a rename can
// never desync the writer from the parser.
const K = struct {
    const version = "version";
    const name = "name";
    const boss = "boss";
    const size = "size";
    const half = "half"; // legacy v1 square arena, read-only
    const floor = "floor"; // legacy v1-v3 3-material set; now read as floorBase (rest discarded)
    const floorbase = "floorbase"; // fill material + decor/minimap tone
    const fm = "fm"; // one RLE run of the paintable floor grid: <material> <count>
    const ground = "ground"; // legacy v1/v2 palette, read-and-discarded
    const accent = "accent"; // legacy v1/v2 palette, read-and-discarded
    const light = "light";
    const spawn = "spawn";
    const portal = "portal";
    const bossat = "bossat";
    const ledge = "ledge";
    const ramp = "ramp";
    const ob = "ob";
    const decor = "decor";
    const pack = "pack";
    const region = "region";
    const npc = "npc";
    // Trigger-layer keys (str/switch/counter/trig/tcond/tact) are owned + spelled by
    // trigger.zig; map.load delegates them via trigger.parseLine.
};

pub fn save(m: *const Map, path: []const u8) !void {
    std.fs.cwd().makePath(dir) catch {};
    // Keep a .bak of whatever was there before, so we never clobber the only copy.
    // Sized off PATH_CAP so raising the path cap can't silently outgrow this buffer.
    var bakBuf: [PATH_CAP + bak_ext.len]u8 = undefined;
    if (std.fmt.bufPrint(&bakBuf, "{s}" ++ bak_ext, .{path})) |bak| {
        std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{}) catch {};
    } else |_| {}

    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try writeMap(f.writer(), m);
}

// Serialize a map to any writer — shared by save() (to a file) and the round-trip test (to
// a buffer), so the on-disk format and what the test exercises can never drift apart.
pub fn writeMap(w: anytype, m: *const Map) !void {
    try w.print(K.version ++ ": {d}\n", .{FORMAT_VERSION});
    try w.print(K.name ++ ": {s}\n", .{m.name.slice()});
    try w.print(K.boss ++ ": {s}\n", .{m.boss.slice()});
    try w.print(K.size ++ ": {d:.1} {d:.1}\n", .{ m.halfW, m.halfD });
    try w.print(K.floorbase ++ ": {s}\n", .{@tagName(m.floorBase)});
    // Paintable floor grid, RLE by run of equal cells (a fresh all-grass map is one line).
    {
        var i: usize = 0;
        while (i < m.floorGrid.len) {
            const v = m.floorGrid[i];
            var run: usize = 1;
            while (i + run < m.floorGrid.len and m.floorGrid[i + run] == v) run += 1;
            const mat: world.FloorMat = @enumFromInt(@min(v, world.FloorMat.count - 1));
            try w.print(K.fm ++ ": {s} {d}\n", .{ @tagName(mat), run });
            i += run;
        }
    }
    try w.print(K.light ++ ": {d:.2} {d:.2} {d:.2}\n", .{ m.light[0], m.light[1], m.light[2] });
    try w.print(K.spawn ++ ": {d:.1} {d:.1}\n", .{ m.spawn.x, m.spawn.z });
    try w.print(K.portal ++ ": {d:.1} {d:.1}\n", .{ m.portal.x, m.portal.z });
    try w.print(K.bossat ++ ": {d:.1} {d:.1}\n", .{ m.bossPos.x, m.bossPos.z });
    for (m.ledges[0..m.ledge_count]) |l| {
        try w.print(K.ledge ++ ": {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}\n", .{ l.minX, l.minZ, l.maxX, l.maxZ, l.h });
    }
    for (m.ramps[0..m.ramp_count]) |r| {
        try w.print(K.ramp ++ ": {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {s}\n", .{ r.minX, r.minZ, r.maxX, r.maxZ, r.h, @tagName(r.rise) });
    }
    for (m.obstacles[0..m.obstacle_count]) |o| {
        try w.print(K.ob ++ ": {s} {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ @tagName(o.Kind), o.Pos.x, o.Pos.z, o.Radius, o.Height });
    }
    for (m.decor[0..m.decor_count]) |d| {
        try w.print(K.decor ++ ": {s} {d:.2} {d:.2} {d:.2}\n", .{ @tagName(d.Kind), d.Pos.x, d.Pos.z, d.Size });
    }
    for (m.packs[0..m.pack_count]) |p| {
        try w.print(K.pack ++ ": {s} {d} {d:.1} {d:.1}\n", .{ @tagName(p.kind), p.count, p.x, p.z });
    }
    for (m.regions[0..m.region_count]) |r| {
        try w.print(K.region ++ ": {d:.1} {d:.1} {d:.1} {d:.1} {s}\n", .{ r.minX, r.minZ, r.maxX, r.maxZ, r.name.slice() });
    }
    for (m.npcs[0..m.npc_count]) |n| {
        try w.print(K.npc ++ ": {s} {d:.1} {d:.1} {d:.1} {s}\n", .{ @tagName(n.kind), n.x, n.z, n.facing, n.name.slice() });
    }
    // Trigger layer writes its own str/switch/counter/trig/tcond/tact lines last.
    try trigger.saveInto(w, &m.trig);
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

fn nextUsize(it: *std.mem.TokenIterator(u8, .scalar)) !usize {
    const tok = it.next() orelse return LoadError.BadLine;
    return std.fmt.parseInt(usize, tok, 10) catch LoadError.BadLine;
}

fn nextEnum(comptime T: type, it: *std.mem.TokenIterator(u8, .scalar)) !T {
    const tok = it.next() orelse return LoadError.BadLine;
    return std.meta.stringToEnum(T, tok) orelse LoadError.BadLine;
}

// Three u8 channels → an opaque color: `ground`/`accent` share one reader so their
// parse can't drift. Caller adds the field name via its `catch return fail(...)`.
fn nextColor(it: *std.mem.TokenIterator(u8, .scalar)) !rl.Color {
    const r = try nextU8(it);
    const g = try nextU8(it);
    const b = try nextU8(it);
    return rgba(r, g, b, 255);
}

// Two floats → a ground-plane point (y=0): spawn/portal/bossat share one reader.
fn nextXZ(it: *std.mem.TokenIterator(u8, .scalar)) !rl.Vector3 {
    const x = try nextF32(it);
    const z = try nextF32(it);
    return v3(x, 0, z);
}

// Keys whose payload is arbitrary free text: they consume the whole `rest` and must
// NOT be tokenized or trailing-checked. One predicate so the load arm and the
// trailing-data guard agree on the set.
fn isFreeText(key: []const u8) bool {
    return std.mem.eql(u8, key, K.name) or std.mem.eql(u8, key, K.boss);
}

// Region/Npc lines: a few fixed tokens then a free-text NAME tail (read via it.rest()).
// Returns .not_mine WITHOUT touching `it` for other keys, so map.load's own chain still
// sees a pristine iterator. Reuses trigger.ParseResult (same three-way shape).
fn parseTownLine(m: *Map, key: []const u8, it: *std.mem.TokenIterator(u8, .scalar)) trigger.ParseResult {
    if (std.mem.eql(u8, key, K.region)) {
        if (m.region_count >= MAX_REGIONS) return .bad;
        var r = Region{};
        r.minX = nextF32(it) catch return .bad;
        r.minZ = nextF32(it) catch return .bad;
        r.maxX = nextF32(it) catch return .bad;
        r.maxZ = nextF32(it) catch return .bad;
        r.name.set(std.mem.trimLeft(u8, it.rest(), " "));
        m.regions[m.region_count] = r;
        m.region_count += 1;
        return .handled;
    } else if (std.mem.eql(u8, key, K.npc)) {
        if (m.npc_count >= MAX_NPCS) return .bad;
        var n = Npc{};
        n.kind = nextEnum(NpcKind, it) catch return .bad;
        n.x = nextF32(it) catch return .bad;
        n.z = nextF32(it) catch return .bad;
        n.facing = nextF32(it) catch return .bad;
        n.name.set(std.mem.trimLeft(u8, it.rest(), " "));
        m.npcs[m.npc_count] = n;
        m.npc_count += 1;
        return .handled;
    }
    return .not_mine;
}

pub fn load(path: []const u8) LoadError!Map {
    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return LoadError.ReadFailed;
    defer alloc.free(data);
    return parseBuf(data);
}

// Parse a map from an in-memory buffer — the body of load(), split out so it round-trips
// against writeMap() in a unit test without touching disk.
pub fn parseBuf(data: []const u8) LoadError!Map {
    var m = Map{};
    var sawVersion = false;
    var floorCursor: usize = 0; // fill position for the fm: RLE runs
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

        // Town data (region/npc) and the trigger layer own a set of keys with free-text
        // tails; they validate + consume the line themselves, so a `.handled` line skips
        // the tokenized if/else AND the trailing-data check below. On `.not_mine` neither
        // touched `it`, so the chain proceeds unaffected.
        switch (parseTownLine(&m, key, &it)) {
            .handled => continue,
            .bad => return fail(lineNo, line, "bad region/npc line"),
            .not_mine => {},
        }
        switch (trigger.parseLine(&m.trig, key, &it)) {
            .handled => continue,
            .bad => return fail(lineNo, line, "bad trigger line"),
            .not_mine => {},
        }

        if (std.mem.eql(u8, key, K.version)) {
            const ver = nextF32(&it) catch return fail(lineNo, line, "bad version");
            // Compare as float (never @intFromFloat an unvalidated parse — huge/inf/NaN
            // makes the cast illegal). Require an INTEGER 1 <= ver <= FORMAT_VERSION: the
            // negated range check also rejects NaN, the lower bound rejects a truncated/typo'd
            // value (0, negative), and the integrality check rejects a mangled "2.5" that
            // would otherwise load silently under the wrong format semantics.
            if (!(ver >= 1 and ver <= @as(f32, @floatFromInt(FORMAT_VERSION))) or ver != @floor(ver)) return fail(lineNo, line, "unsupported map format version");
            sawVersion = true;
        } else if (std.mem.eql(u8, key, K.name)) {
            m.name.set(rest);
        } else if (std.mem.eql(u8, key, K.boss)) {
            m.boss.set(rest);
        } else if (std.mem.eql(u8, key, K.size)) {
            m.halfW = nextF32(&it) catch return fail(lineNo, line, "bad size");
            m.halfD = nextF32(&it) catch return fail(lineNo, line, "bad size");
        } else if (std.mem.eql(u8, key, K.half)) {
            // Legacy v1 square arena: one extent for both axes.
            m.halfW = nextF32(&it) catch return fail(lineNo, line, "bad half");
            m.halfD = m.halfW;
        } else if (std.mem.eql(u8, key, K.floor)) {
            // Legacy v1-v3 3-material set: keep the PRIMARY as the base fill, discard the rest.
            m.floorBase = nextEnum(world.FloorMat, &it) catch return fail(lineNo, line, "bad floor material");
            _ = nextEnum(world.FloorMat, &it) catch return fail(lineNo, line, "bad floor material");
            _ = nextEnum(world.FloorMat, &it) catch return fail(lineNo, line, "bad floor material");
        } else if (std.mem.eql(u8, key, K.floorbase)) {
            m.floorBase = nextEnum(world.FloorMat, &it) catch return fail(lineNo, line, "bad floorbase");
        } else if (std.mem.eql(u8, key, K.fm)) {
            const mat = nextEnum(world.FloorMat, &it) catch return fail(lineNo, line, "bad floor tile");
            const cnt = nextUsize(&it) catch return fail(lineNo, line, "bad floor run");
            var k: usize = 0;
            while (k < cnt and floorCursor < m.floorGrid.len) : (k += 1) {
                m.floorGrid[floorCursor] = @intFromEnum(mat);
                floorCursor += 1;
            }
        } else if (std.mem.eql(u8, key, K.ground) or std.mem.eql(u8, key, K.accent)) {
            // Legacy v1/v2 palette: parse (so trailing-data checks still bite) and
            // discard — the floor materials own the ground look now.
            _ = nextColor(&it) catch return fail(lineNo, line, "bad legacy palette");
        } else if (std.mem.eql(u8, key, K.light)) {
            for (0..3) |i| m.light[i] = nextF32(&it) catch return fail(lineNo, line, "bad light");
        } else if (std.mem.eql(u8, key, K.spawn)) {
            m.spawn = nextXZ(&it) catch return fail(lineNo, line, "bad spawn");
        } else if (std.mem.eql(u8, key, K.portal)) {
            m.portal = nextXZ(&it) catch return fail(lineNo, line, "bad portal");
        } else if (std.mem.eql(u8, key, K.bossat)) {
            m.bossPos = nextXZ(&it) catch return fail(lineNo, line, "bad bossat");
        } else if (std.mem.eql(u8, key, K.ledge)) {
            if (m.ledge_count >= world.MAX_LEDGES) return fail(lineNo, line, "too many ledges");
            m.ledges[m.ledge_count] = .{
                .minX = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .minZ = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .maxX = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .maxZ = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
                .h = nextF32(&it) catch return fail(lineNo, line, "bad ledge"),
            };
            m.ledge_count += 1;
        } else if (std.mem.eql(u8, key, K.ramp)) {
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
        } else if (std.mem.eql(u8, key, K.ob)) {
            if (m.obstacle_count >= world.MAX_OBSTACLES) return fail(lineNo, line, "too many obstacles");
            const kind = nextEnum(world.ObstacleKind, &it) catch return fail(lineNo, line, "bad obstacle kind");
            m.obstacles[m.obstacle_count] = .{
                .Kind = kind,
                .Pos = v3(nextF32(&it) catch return fail(lineNo, line, "bad ob"), 0, nextF32(&it) catch return fail(lineNo, line, "bad ob")),
                .Radius = nextF32(&it) catch return fail(lineNo, line, "bad ob"),
                .Height = nextF32(&it) catch return fail(lineNo, line, "bad ob"),
            };
            m.obstacle_count += 1;
        } else if (std.mem.eql(u8, key, K.decor)) {
            if (m.decor_count >= world.MAX_DECOR) return fail(lineNo, line, "too many decor");
            const kind = nextEnum(world.DecorKind, &it) catch return fail(lineNo, line, "bad decor kind");
            m.decor[m.decor_count] = .{
                .Kind = kind,
                .Pos = v3(nextF32(&it) catch return fail(lineNo, line, "bad decor"), 0, nextF32(&it) catch return fail(lineNo, line, "bad decor")),
                .Size = nextF32(&it) catch return fail(lineNo, line, "bad decor"),
            };
            m.decor_count += 1;
        } else if (std.mem.eql(u8, key, K.pack)) {
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
        // unknown keys. Free-text keys hold arbitrary words and never tokenize.
        if (!isFreeText(key) and it.next() != null) {
            return fail(lineNo, line, "trailing data");
        }
    }
    // Legacy maps (no fm: lines) fill the whole grid with the base material.
    if (floorCursor == 0) @memset(m.floorGrid[0..], @intFromEnum(m.floorBase));
    if (!sawVersion) {
        std.debug.print("map load error: no 'version:' header\n", .{});
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
    m.halfW = std.math.clamp(m.halfW, HALF_MIN, HALF_MAX);
    m.halfD = std.math.clamp(m.halfD, HALF_MIN, HALF_MAX);
    if (m.name.len == 0) m.name.set("Unnamed");
    if (m.boss.len == 0) m.boss.set("Champion");
    // Clamp every stored coordinate to the arena walls. nextF32 rejected inf/NaN, but
    // a finite-but-HUGE value (e.g. `ledge: 1e18`) would still crash an @intFromFloat
    // in the editor minimap and place content in the void. No-op for in-arena maps.
    const hw = m.halfW;
    const hd = m.halfD;
    for ([_]*rl.Vector3{ &m.spawn, &m.portal, &m.bossPos }) |a| {
        a.x = std.math.clamp(a.x, -hw, hw);
        a.z = std.math.clamp(a.z, -hd, hd);
    }
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
        p.count = std.math.clamp(p.count, PACK_MEMBERS_MIN, PACK_MEMBERS_MAX);
        p.x = std.math.clamp(p.x, -hw, hw);
        p.z = std.math.clamp(p.z, -hd, hd);
    }
    for (m.regions[0..m.region_count]) |*r| {
        if (r.minX > r.maxX) std.mem.swap(f32, &r.minX, &r.maxX);
        if (r.minZ > r.maxZ) std.mem.swap(f32, &r.minZ, &r.maxZ);
        r.minX = std.math.clamp(r.minX, -hw, hw);
        r.maxX = std.math.clamp(r.maxX, -hw, hw);
        r.minZ = std.math.clamp(r.minZ, -hd, hd);
        r.maxZ = std.math.clamp(r.maxZ, -hd, hd);
        if (r.name.len == 0) r.name.set("Region");
    }
    for (m.npcs[0..m.npc_count]) |*n| {
        n.x = std.math.clamp(n.x, -hw, hw);
        n.z = std.math.clamp(n.z, -hd, hd);
        if (n.name.len == 0) n.name.set("Stranger");
    }
    // A hand-edited fm: run could name an out-of-range id; collapse it to the base material.
    for (m.floorGrid[0..]) |*c| {
        if (c.* >= world.FloorMat.count) c.* = @intFromEnum(m.floorBase);
    }
    // Collapse any hand-edited trigger ref that points past the pools it names, so a bogus
    // index can't read out of bounds when the trigger runtime dereferences it.
    trigger.sanitize(&m.trig, m.region_count, m.npc_count);
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
        const full = std.fmt.bufPrint(&paths[n], "{s}/{s}", .{ dir, entry.name }) catch {
            // Campaign order is load-bearing — a silently skipped map shifts every tier.
            std.debug.print("map list error: {s}/{s} exceeds PATH_CAP {d}, skipped\n", .{ dir, entry.name, PATH_CAP });
            continue;
        };
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

test "map writeMap→parseBuf round-trips town data (region, npc, conversation trigger)" {
    const t = std.testing;
    var m = Map{};
    m.name.set("Test Town");
    m.boss.set("None");
    m.regions[0] = .{ .minX = -4, .minZ = 26, .maxX = 4, .maxZ = 29 };
    m.regions[0].name.set("Town Gate");
    m.region_count = 1;
    m.npcs[0] = .{ .kind = .elder, .x = 0, .z = 24, .facing = 180 };
    m.npcs[0].name.set("Old Marius");
    m.npc_count = 1;

    const greet = m.trig.addString("Winter's been cruel, friend.").?;
    const learn = m.trig.addString("Teach me firebolt.").?;
    _ = m.trig.addSwitch("MetElder").?;
    const tr = m.trig.addTrigger("Greet the elder").?;
    tr.conds[0] = .{ .on_talk = 0 };
    tr.cond_count = 1;
    tr.acts[0] = .{ .say = .{ .npc = 0, .text = greet } };
    tr.acts[1] = .{ .choice = learn };
    tr.acts[2] = .{ .grant_skill = .firebolt };
    tr.acts[3] = .end_choice;
    tr.acts[4] = .end_dialogue;
    tr.act_count = 5;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeMap(fbs.writer(), &m);
    const m2 = try parseBuf(fbs.getWritten());

    try t.expectEqual(@as(usize, 1), m2.region_count);
    try t.expectEqualStrings("Town Gate", m2.regions[0].name.slice());
    try t.expectEqual(@as(usize, 1), m2.npc_count);
    try t.expect(m2.npcs[0].kind == .elder);
    try t.expectEqualStrings("Old Marius", m2.npcs[0].name.slice());
    try t.expectEqual(@as(usize, 1), m2.trig.trigger_count);
    try t.expectEqualStrings("Greet the elder", m2.trig.triggers[0].name.slice());
    try t.expectEqual(@as(usize, 5), m2.trig.triggers[0].act_count);
    try t.expect(m2.trig.triggers[0].conds[0] == .on_talk);
    try t.expect(m2.trig.triggers[0].acts[2].grant_skill == .firebolt);
    try t.expectEqualStrings("Winter's been cruel, friend.", m2.trig.stringText(greet));
}
