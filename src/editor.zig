const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");
const mapmod = @import("map.zig");
const monster = @import("monster.zig");
const gamemod = @import("game.zig");
const hudx = @import("hudx.zig");
const theme = @import("theme.zig");
const tl = @import("torchlight.zig");
const ui = @import("ui.zig");
const cameramod = @import("camera.zig");

const Game = gamemod.Game;
const v3 = mathx.v3;
const rgba = mathx.rgba;
const distXZ = mathx.distXZ;
const clampF = mathx.clampF;
const withAlpha = mathx.withAlpha;
const lerpColor = mathx.lerpColor;

// EDITOR — an in-game scene: same window/renderer/terrain-picking as play, so the
// edited map is exactly what players see. Current map is Game.map; every edit
// re-materializes Game.w + the baked mesh, so the world IS the live preview. F5
// playtests the in-memory map (Ctrl+F5 starts at the cursor); exit returns here.
//
// Workspace is organized in LAYERS: Floor (ledge/ramp drag-rects), Decor (paint
// brushes + scatter), Props (stamps), Entities (packs/boss/spawn/portal). Each
// layer ends in its own ERASE brush, scoped to that layer only.
//
// Interaction grammar: LEFT paints (drag to sweep; one undo step/stroke),
// RIGHT-CLICK opens the context menu, RIGHT-DRAG pans (4 px threshold splits
// them), wheel zooms, Tab cycles layers, 1..9 pick brushes, Alt off-grid, M mirrors X.

pub const Layer = enum(u8) {
    floor,
    decor,
    props,
    entities,

    // Layer count: drives Tab-cycle span, Alt-jump bound, and brushSel[] size.
    pub const N = @typeInfo(Layer).@"enum".fields.len;

    fn label(l: Layer) [:0]const u8 {
        return switch (l) {
            .floor => "Floor",
            .decor => "Decor",
            .props => "Props",
            .entities => "Entities",
        };
    }
};

// Brush tables (last entry of every layer is its scoped eraser).
const floorBrushes = [_][:0]const u8{ "Ledge", "Ramp", "Erase" };
const decorBrushes = [_][:0]const u8{ "pebble", "tuft", "shroom", "bone", "Erase" };
const propBrushes = [_][:0]const u8{ "rock", "tree", "gravestone", "Erase" };
const entityBrushes = [_][:0]const u8{ "pib pack", "zombie pack", "skeleton pack", "brute pack", "Boss", "Spawn", "Portal", "Erase" };

fn brushesFor(l: Layer) []const [:0]const u8 {
    return switch (l) {
        .floor => &floorBrushes,
        .decor => &decorBrushes,
        .props => &propBrushes,
        .entities => &entityBrushes,
    };
}

// Hover blurbs (ui.buttonTip) for the layer strip and every brush.
const layerTips = [_][:0]const u8{
    "Terrain shaping: ledges + ramps (Tab cycles layers)",
    "Ground dressing: paint or scatter, never blocks",
    "Blocking scenery: rocks, trees, gravestones",
    "Foe packs, the boss, player spawn, the portal",
};
const floorTips = [_][:0]const u8{
    "Drag a rectangle; [ ] sets its height",
    "Drag a rectangle; R (or chips) sets the rise",
    "Click a ledge or ramp to remove it",
};
const decorTips = [_][:0]const u8{
    "Paint pebbles (drag to sweep)",
    "Paint grass tufts (drag to sweep)",
    "Paint mushrooms (drag to sweep)",
    "Paint old bones (drag to sweep)",
    "Sweep-erase DECOR only ([ ] sets radius)",
};
const propTips = [_][:0]const u8{
    "Stamp boulders (snaps to grid; Alt = free)",
    "Stamp trees (snaps to grid; Alt = free)",
    "Stamp gravestones (snaps to grid; Alt = free)",
    "Sweep-erase PROPS only ([ ] sets radius)",
};
const entityTips = [_][:0]const u8{
    "Place a pib pack; click a pack to grab or edit it",
    "Place a zombie pack; click a pack to grab or edit it",
    "Place a skeleton pack; click a pack to grab or edit it",
    "Place a brute pack; click a pack to grab or edit it",
    "Move the area champion's post",
    "Move where the hero enters",
    "Move the area exit",
    "Click-erase PACKS only ([ ] sets radius)",
};

fn brushTipsFor(l: Layer) []const [:0]const u8 {
    return switch (l) {
        .floor => &floorTips,
        .decor => &decorTips,
        .props => &propTips,
        .entities => &entityTips,
    };
}

comptime {
    std.debug.assert(layerTips.len == Layer.N); // indexed by layer ordinal
    std.debug.assert(floorTips.len == floorBrushes.len);
    std.debug.assert(decorTips.len == decorBrushes.len);
    std.debug.assert(propTips.len == propBrushes.len);
    std.debug.assert(entityTips.len == entityBrushes.len);
}

// Brush tables and their decoders (decorKind/propKind/entityBrush) are parallel
// lists: pin lengths so adding a kind can't silently skew the index mapping.
comptime {
    std.debug.assert(floorBrushes.len == @typeInfo(FloorBrush).@"enum".fields.len);
    std.debug.assert(decorBrushes.len == @typeInfo(world.DecorKind).@"enum".fields.len + 1);
    std.debug.assert(propBrushes.len == @typeInfo(world.ObstacleKind).@"enum".fields.len + 1);
    // packs (one per MonsterKind) + non-pack EntityBrush variants (all but .pack).
    std.debug.assert(entityBrushes.len == @typeInfo(monster.MonsterKind).@"enum".fields.len + @typeInfo(EntityBrush).@"enum".fields.len - 1);
    // decor/props labels ARE the enum tag names — pin the ORDER, not just the length,
    // so reordering DecorKind/ObstacleKind without reordering the brush table is a
    // compile error (the decoders index enum-by-ordinal). Floor/entity labels are
    // stylized ("Ledge", "pib pack") so their order stays a hand-kept convention.
    for (0..@typeInfo(world.DecorKind).@"enum".fields.len) |i| {
        std.debug.assert(std.mem.eql(u8, decorBrushes[i], @tagName(@as(world.DecorKind, @enumFromInt(i)))));
    }
    for (0..@typeInfo(world.ObstacleKind).@"enum".fields.len) |i| {
        std.debug.assert(std.mem.eql(u8, propBrushes[i], @tagName(@as(world.ObstacleKind, @enumFromInt(i)))));
    }
}

// Floor-layer brush index (positional, matching floorBrushes).
const FloorBrush = enum { ledge, ramp, erase };

// Entities-layer brush index.
const EntityBrush = enum { pack, boss, spawn, portal, erase };

// Marker identity colors, shared by 3D anchors and minimap glyphs.
const SPAWN_COL = rgba(140, 200, 255, 255);
const PORTAL_COL = rgba(190, 140, 255, 255);
const BOSS_COL = rgba(255, 80, 80, 255);

// Anchor ring radii, shared by the drawn ring AND its hover-pick zone so a resized
// ring never lies about what's clickable. Hover zone = ring + MARKER_HOVER_PAD.
const SPAWN_R = 1.0;
const PORTAL_R = 1.4;
const BOSS_R = 1.2;
const MARKER_HOVER_PAD = 0.2;

// Pack ring radius doubles as the grab pickup radius (clickable == visible).
const PACK_GRAB_R = 1.6;

// Right-drag pan deadzone (px): a right-click only becomes a pan past this move, so a
// click-in-place opens the context menu instead. The crawler-editor "4 px threshold".
const RIGHT_DRAG_PX = 4;

// Editor sun: high over the camera target, wide enough to light the view. Follows
// camTarget (not arena center), so its radius spans the lit region around the focus
// rather than the whole map — comfortable for any authored extent (HALF_MAX).
const EDITOR_SUN_H = 38.0;
const EDITOR_SUN_R = 110.0;

pub const Modal = enum { none, save_as, new_map, open_map, rename, confirm, pack_edit };
pub const Pending = enum { none, open, new, exit };

// ---- Marquee selection + clipboard (Shift+drag selects, drag inside moves,
// Ctrl+C/X/V copy/cut/paste, Del deletes, Esc clears) ----

const SelRect = struct {
    minX: f32,
    minZ: f32,
    maxX: f32,
    maxZ: f32,

    fn contains(s: SelRect, x: f32, z: f32) bool {
        return world.inRect(s.minX, s.maxX, s.minZ, s.maxZ, x, z);
    }
    fn cx(s: SelRect) f32 {
        return (s.minX + s.maxX) / 2;
    }
    fn cz(s: SelRect) f32 {
        return (s.minZ + s.maxZ) / 2;
    }
};

fn normRect(a: rl.Vector3, b: rl.Vector3) SelRect {
    return .{
        .minX = @min(a.x, b.x),
        .minZ = @min(a.z, b.z),
        .maxX = @max(a.x, b.x),
        .maxZ = @max(a.z, b.z),
    };
}

// Clipboard holds objects RELATIVE to the copied rect's center, so a paste lands
// the arrangement on the cursor. Terrain features are deliberately excluded.
var clipProps: [world.MAX_OBSTACLES]world.Obstacle = undefined;
var clipPropN: usize = 0;
var clipDecor: [world.MAX_DECOR]world.Decor = undefined;
var clipDecorN: usize = 0;
var clipPacks: [mapmod.MAX_PACKS]mapmod.Pack = undefined;
var clipPackN: usize = 0;
var clipHas = false;
var selBankPending = false; // selection-move undo banks on first movement only

// Palette presets applied in one click: ground, accent, and torch light together.
const Preset = struct { name: [:0]const u8, ground: rl.Color, accent: rl.Color, light: [3]f32 };
const presets = [_]Preset{
    .{ .name = "Moor", .ground = mapmod.DEFAULT_GROUND, .accent = mapmod.DEFAULT_ACCENT, .light = .{ 1.04, 0.94, 0.80 } },
    .{ .name = "Plains", .ground = rgba(108, 120, 138, 255), .accent = rgba(86, 96, 112, 255), .light = .{ 0.90, 0.97, 1.08 } },
    .{ .name = "Stony", .ground = rgba(96, 92, 80, 255), .accent = rgba(74, 70, 60, 255), .light = .{ 1.00, 0.96, 0.87 } },
    .{ .name = "Wood", .ground = rgba(62, 58, 48, 255), .accent = rgba(48, 46, 38, 255), .light = .{ 0.88, 1.00, 0.88 } },
    .{ .name = "Crypt", .ground = rgba(54, 46, 60, 255), .accent = rgba(40, 34, 46, 255), .light = .{ 0.93, 0.87, 1.08 } },
};

// ---- Undo/redo: eager whole-map snapshots, cap 50 ----
// Map is a flat ~34 KB value, so by-value history is trivial and aliasing-immune.
// Paint strokes bank ONE step (pre-stroke state) only if the stroke changed
// something (lazy-commit). Static storage.
const UNDO_CAP = 50;
var undoStack: [UNDO_CAP]mapmod.Map = undefined;
var undoLen: usize = 0;
var redoStack: [UNDO_CAP]mapmod.Map = undefined;
var redoLen: usize = 0;
var packEditBefore: mapmod.Map = undefined; // snapshot banked when the pack modal opens
var strokeBefore: mapmod.Map = undefined; // snapshot banked when a paint stroke starts

fn clearHistory() void {
    undoLen = 0;
    redoLen = 0;
}

// Bank the CURRENT map for a mutation about to happen unconditionally. Conditional
// mutations (cap-hitting placements, too-small drags) snapshot locally and bank
// only on success instead.
fn bankUndo(g: *Game) void {
    pushUndoFrom(&g.map);
}

fn pushUndoFrom(before: *const mapmod.Map) void {
    if (undoLen == UNDO_CAP) {
        std.mem.copyForwards(mapmod.Map, undoStack[0 .. UNDO_CAP - 1], undoStack[1..UNDO_CAP]);
        undoLen -= 1;
    }
    undoStack[undoLen] = before.*;
    undoLen += 1;
    redoLen = 0;
}

fn doUndo(g: *Game) void {
    const ed = &g.ed;
    if (ed.dragStart != null or ed.grabIdx != null or ed.strokeActive or ed.selMove != null or ed.selDrag != null) return; // never pop mid-gesture
    if (undoLen == 0) return ed.status("nothing to undo", .{});
    if (redoLen < UNDO_CAP) {
        redoStack[redoLen] = g.map;
        redoLen += 1;
    }
    undoLen -= 1;
    g.map = undoStack[undoLen];
    markDirty(g);
    ed.status("undo ({d} left)", .{undoLen});
}

fn doRedo(g: *Game) void {
    const ed = &g.ed;
    if (ed.dragStart != null or ed.grabIdx != null or ed.strokeActive or ed.selMove != null or ed.selDrag != null) return;
    if (redoLen == 0) return ed.status("nothing to redo", .{});
    if (undoLen < UNDO_CAP) {
        undoStack[undoLen] = g.map;
        undoLen += 1;
    }
    redoLen -= 1;
    g.map = redoStack[redoLen];
    markDirty(g);
    ed.status("redo", .{});
}

pub const Editor = struct {
    layer: Layer = .props,
    brushSel: [Layer.N]usize = .{0} ** Layer.N, // remembered selection per layer
    rise: world.RampRise = .xpos,
    featureH: f32 = 2.4, // height stamped on new ledges/ramps
    packCount: i32 = 3, // members stamped per new pack
    brushR: f32 = 1.5, // sweep radius: erase reach + decor scatter spread
    mirrorX: bool = false, // paint both sides of the X axis at once

    dragStart: ?rl.Vector3 = null, // ledge/ramp rect anchor (while LMB held)
    panAnchor: ?rl.Vector3 = null, // ground point pinned under the cursor (RMB drag)
    camTarget: rl.Vector3 = mathx.zero3,
    dirty: bool = false,
    grid: bool = true,
    uiHot: bool = false, // pointer over chrome LAST frame: world clicks blocked

    // Paint stroke (LMB held on a paint layer): one undo step per stroke.
    strokeActive: bool = false,
    strokeChanged: bool = false,
    lastPaint: rl.Vector3 = mathx.zero3,

    // Marquee selection (Shift+drag): a world-rect of objects to move/copy/cut.
    sel: ?SelRect = null,
    selDrag: ?rl.Vector3 = null, // marquee anchor while Shift+LMB held
    selMove: ?rl.Vector3 = null, // last ground point while dragging contents

    // Right-button click-vs-drag disambiguation (4 px threshold).
    rightStart: rl.Vector2 = .{ .x = 0, .y = 0 },
    rightMoved: bool = false,

    // Context menu (right-CLICK): screen anchor + world point it acts on.
    ctxOpen: bool = false,
    ctxAt: rl.Vector2 = .{ .x = 0, .y = 0 },
    ctxWorld: rl.Vector3 = mathx.zero3,

    // Pack drag-move: press on a pack grabs it; release in place opens its edit
    // modal, release elsewhere moves it.
    grabIdx: ?usize = null,
    grabStart: rl.Vector3 = mathx.zero3,
    packEditIdx: usize = 0,

    recovT: f32 = 0, // seconds since the last crash-recovery autosave while dirty

    // Where Ctrl+S writes. Empty until the map's been saved; then Ctrl+S opens
    // Save As instead of guessing a filename.
    path_buf: [mapmod.PATH_CAP]u8 = [_]u8{0} ** mapmod.PATH_CAP,
    path_len: usize = 0,

    modal: Modal = .none,
    pending: Pending = .none, // what the confirm modal resumes on Save/Discard
    pendingOpen: usize = 0,
    field_buf: [40]u8 = [_]u8{0} ** 40, // modal text input
    field_len: usize = 0,
    newHalfW: f32 = 30,
    newHalfD: f32 = 30,

    status_buf: [ui.MSG_CAP]u8 = [_]u8{0} ** ui.MSG_CAP,
    status_len: usize = 0,
    status_t: f32 = 0,

    pub fn status(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrintZ(&ed.status_buf, fmt, args) catch return;
        ed.status_len = s.len;
        ed.status_t = STATUS_SECS;
    }

    fn path(ed: *const Editor) []const u8 {
        return ed.path_buf[0..ed.path_len];
    }

    fn setPath(ed: *Editor, p: []const u8) void {
        const n = @min(p.len, ed.path_buf.len);
        @memcpy(ed.path_buf[0..n], p[0..n]);
        ed.path_len = n;
    }

    fn brush(ed: *const Editor) usize {
        return ed.brushSel[@intFromEnum(ed.layer)];
    }

    fn setBrush(ed: *Editor, i: usize) void {
        ed.brushSel[@intFromEnum(ed.layer)] = @min(i, brushesFor(ed.layer).len - 1);
    }

    fn isEraseBrush(ed: *const Editor) bool {
        return ed.brush() == brushesFor(ed.layer).len - 1;
    }

    fn decorKind(ed: *const Editor) world.DecorKind {
        return @enumFromInt(@min(ed.brush(), lastVariant(world.DecorKind)));
    }

    fn propKind(ed: *const Editor) world.ObstacleKind {
        return @enumFromInt(@min(ed.brush(), lastVariant(world.ObstacleKind)));
    }

    fn floorBrush(ed: *const Editor) FloorBrush {
        return @enumFromInt(@min(ed.brush(), @typeInfo(FloorBrush).@"enum".fields.len - 1));
    }

    fn entityBrush(ed: *const Editor) EntityBrush {
        // First N brushes are the N monster-kind packs (decode to .pack); the tail
        // maps 1:1 onto EntityBrush's non-pack variants IN ORDER, so a new brush
        // decodes correctly rather than collapsing to .erase. EntityBrush's order must
        // match entityBrushes' tail — the comptime assert pins only the LENGTH (labels
        // are stylized, not tag names), so this ordering is a hand-kept convention.
        const nPacks = @typeInfo(monster.MonsterKind).@"enum".fields.len;
        const b = ed.brush();
        if (b < nPacks) return .pack;
        // setBrush clamps b, so b - nPacks + 1 is always a valid ordinal (.pack is 0).
        return @enumFromInt(b - nPacks + 1);
    }

    fn packKind(ed: *const Editor) monster.MonsterKind {
        return @enumFromInt(@min(ed.brush(), lastVariant(monster.MonsterKind)));
    }
};

// Highest valid @intFromEnum for T. Brush tables end in a non-kind entry (eraser),
// so the raw brush index clamps to a real kind through this rather than a drifting
// hand-copied max.
fn lastVariant(comptime T: type) usize {
    return @typeInfo(T).@"enum".fields.len - 1;
}

// ---- Crash-recovery autosave: non-.map extension so it never shows in Open or the
// campaign; never touches the real file; cleared on save/exit ----

const REC_PATH = mapmod.dir ++ "/recovery.autosave";
const REC_INTERVAL = 20.0;
const STATUS_SECS = 2.5; // how long a status toast lingers before fading

fn clearRecovery() void {
    std.fs.cwd().deleteFile(REC_PATH) catch {};
    std.fs.cwd().deleteFile(REC_PATH ++ ".bak") catch {};
}

fn recoveryExists() bool {
    std.fs.cwd().access(REC_PATH, .{}) catch return false;
    return true;
}

/// Enter the editor on the current campaign map. doOpen does the load; enter only
/// adds the recovery hint + scene.
pub fn enter(g: *Game) void {
    // The editor destructively rebuilds the shared world/monsters/fog, so any paused
    // adventure is no longer resumable — the menu must offer a fresh start, not a
    // "Continue" into an emptied, editor-clobbered level.
    g.canResume = false;
    doOpen(g, g.areaIndex);
    if (recoveryExists()) g.ed.status("crash recovery found - Ctrl+R restores it", .{});
    g.scene = .editor;
}

// Re-materialize the live world from the edited map: rebuild the baked mesh, clear
// the fog (author sees everything), empty the dynamic lists.
pub fn apply(g: *Game) void {
    g.w = mapmod.toWorld(&g.map, g.areaIndex == g.lastArea);
    g.sceneMesh.rebuild(&g.w);
    g.fog.revealAll(g.w.HalfW, g.w.HalfD);
    g.fog.sync();
    g.torch.setLightColor(g.map.light);
    g.monsterCount = 0;
    g.projs.count = 0;
    g.lootList.clearRetainingCapacity();
    g.gasCount = 0;
    g.parts.clear();
}

fn markDirty(g: *Game) void {
    g.ed.dirty = true;
    apply(g);
}

// Ground point under the mouse (terrain-aware, same picking as play).
fn mousePoint(g: *Game) ?rl.Vector3 {
    const ray = rl.getScreenToWorldRay(rl.getMousePosition(), g.rig.cam);
    return g.w.pickGround(ray);
}

// Grid snapping (grid is GRID-spaced): props/entities land on CELL CENTERS, terrain
// rects on LINES. Decor never snaps (dressing shouldn't march in rows); Alt places freely.
const GRID = 2.0;

// Keep content and fixed anchors inside the arena wall on shrink or edge paste.
// Objects sit a little closer to the wall than the spawn/portal/boss anchors.
const CONTENT_INSET = 1.2;
const ANCHOR_INSET = 2.0;

// Smallest usable ledge/ramp footprint. Same bound rejects too-small drags at commit
// and drops resize-collapsed features, so you can't end up with an un-authorable one.
const FEATURE_MIN_SPAN = 1.5;

// Editor tuning ranges. Each min/max/step is the single source shared by the [ / ]
// hotkeys AND the panel stepper, so the two paths can't clamp to different bounds.
const FEATURE_H_MIN = 1.2;
const FEATURE_H_MAX = 4.0;
const FEATURE_H_STEP = 0.4;
const BRUSH_R_MIN = 0.5;
const BRUSH_R_MAX = 4.0;
const BRUSH_R_STEP = 0.5;
// Arena half-extent authoring range (New Map + width/depth steppers). Narrower than
// map.sanitize's load tolerance on purpose: the loader accepts hand-edited maps the
// UI won't author.
const HALF_MIN = 18;
const HALF_MAX = 48;
const HALF_STEP = 4;
// Members per pack (PACK panel stepper and pack-edit modal).
const PACK_MIN = 1;
const PACK_MAX = 8;

fn freePlace() bool {
    return rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
}

// The pick plane is infinite, so a click past the wall picks a ground point in the
// void. Clamp at placement: out-of-wall content spawns unreachable monsters (playtest
// softlock) and map.sanitize silently relocates it on next load (saved != authored).
// Same insets as clampContents/pasteAt: content sits closer to the wall than anchors.
fn clampInto(m: *const mapmod.Map, p: rl.Vector3, inset: f32) rl.Vector3 {
    const limW = m.halfW - inset;
    const limD = m.halfD - inset;
    return v3(clampF(p.x, -limW, limW), p.y, clampF(p.z, -limD, limD));
}

fn clampContent(m: *const mapmod.Map, p: rl.Vector3) rl.Vector3 {
    return clampInto(m, p, CONTENT_INSET);
}

fn clampAnchor(m: *const mapmod.Map, p: rl.Vector3) rl.Vector3 {
    return clampInto(m, p, ANCHOR_INSET); // content sits closer to the wall than anchors
}

fn snapCenter(p: rl.Vector3) rl.Vector3 {
    return v3(@floor(p.x / GRID) * GRID + GRID / 2, p.y, @floor(p.z / GRID) * GRID + GRID / 2);
}

fn snapLine(p: rl.Vector3) rl.Vector3 {
    return v3(@round(p.x / GRID) * GRID, p.y, @round(p.z / GRID) * GRID);
}

// Where the active brush would actually place things for this mouse point.
fn toolPoint(ed: *const Editor, p: rl.Vector3) rl.Vector3 {
    if (freePlace() or ed.isEraseBrush()) return p;
    return switch (ed.layer) {
        .floor => snapLine(p),
        .decor => p,
        .props, .entities => snapCenter(p),
    };
}

// ---- Editing operations (each returns whether the map changed) ----

fn placeProp(g: *Game, p_in: rl.Vector3) bool {
    const ed = &g.ed;
    const m = &g.map;
    if (m.obstacle_count >= world.MAX_OBSTACLES) {
        ed.status("prop limit reached", .{});
        return false;
    }
    const p = clampContent(m, p_in);
    const kind = ed.propKind();
    const h = mapmod.hashAt(p.x, p.z);
    m.obstacles[m.obstacle_count] = .{
        .Kind = kind,
        .Pos = v3(p.x, 0, p.z),
        .Radius = switch (kind) {
            .rock => 1.0 + h * 0.8,
            .tree => 0.9 + h * 0.5,
            .gravestone => 0.7,
        },
        .Height = switch (kind) {
            .rock => 1.2 + h * 1.5,
            .tree => 4 + h * 3,
            .gravestone => 1.6 + h,
        },
    };
    m.obstacle_count += 1;
    return true;
}

// One source for decor stamp sizes: hand brush and scatter tool must agree.
fn decorSize(kind: world.DecorKind, h: f32) f32 {
    return switch (kind) {
        .pebble => 0.1 + h * 0.2,
        .tuft => 0.3 + h * 0.35,
        .shroom => 0.16 + h * 0.14,
        .bone => 0.25 + h * 0.25,
    };
}

fn placeDecor(g: *Game, p_in: rl.Vector3) bool {
    const ed = &g.ed;
    const m = &g.map;
    if (m.decor_count >= world.MAX_DECOR) {
        ed.status("decor limit reached", .{});
        return false;
    }
    const p = clampContent(m, p_in); // covers paint jitter too
    const kind = ed.decorKind();
    m.decor[m.decor_count] = .{
        .Kind = kind,
        .Pos = v3(p.x, 0, p.z),
        .Size = decorSize(kind, mapmod.hashAt(p.x, p.z)),
    };
    m.decor_count += 1;
    return true;
}

fn placePack(g: *Game, p_in: rl.Vector3) bool {
    const ed = &g.ed;
    const m = &g.map;
    if (m.pack_count >= mapmod.MAX_PACKS) {
        ed.status("pack limit reached", .{});
        return false;
    }
    const p = clampContent(m, p_in);
    m.packs[m.pack_count] = .{ .kind = ed.packKind(), .count = ed.packCount, .x = p.x, .z = p.z };
    m.pack_count += 1;
    return true;
}

fn mirrorOf(p: rl.Vector3) rl.Vector3 {
    return v3(-p.x, p.y, p.z);
}

fn wantMirror(ed: *const Editor, p: rl.Vector3) bool {
    return ed.mirrorX and @abs(p.x) > 0.9;
}

// Remove everything of the ACTIVE layer within radius r of p (erase sweep).
fn eraseWithin(g: *Game, p: rl.Vector3, r: f32) bool {
    const m = &g.map;
    var changed = false;
    switch (g.ed.layer) {
        .props => {
            var i: usize = m.obstacle_count;
            while (i > 0) {
                i -= 1;
                if (distXZ(m.obstacles[i].Pos, p) < r) {
                    m.removeObstacle(i);
                    changed = true;
                }
            }
        },
        .decor => {
            var i: usize = m.decor_count;
            while (i > 0) {
                i -= 1;
                if (distXZ(m.decor[i].Pos, p) < r) {
                    m.removeDecor(i);
                    changed = true;
                }
            }
        },
        .entities => {
            var i: usize = m.pack_count;
            while (i > 0) {
                i -= 1;
                if (distXZ(m.packs[i].pos(), p) < r) {
                    m.removePack(i);
                    changed = true;
                }
            }
        },
        .floor => {},
    }
    if (changed) markDirty(g);
    return changed;
}

// ---- Selection operations ----

// Copy (optionally cut) the selection into the clipboard, positions relative to the
// rect center.
fn copySelection(g: *Game, cut: bool) void {
    const ed = &g.ed;
    const s = ed.sel orelse return ed.status("nothing selected (Shift+drag)", .{});
    const cx = s.cx();
    const cz = s.cz();
    const m = &g.map;
    // Capture into local counts first: an empty selection must NOT wipe the existing
    // clipboard (the counts/clipHas are committed only once we know the grab is non-empty).
    var np: usize = 0;
    var nd: usize = 0;
    var npk: usize = 0;
    for (m.obstacles[0..m.obstacle_count]) |o| {
        if (s.contains(o.Pos.x, o.Pos.z)) {
            clipProps[np] = o;
            clipProps[np].Pos = v3(o.Pos.x - cx, 0, o.Pos.z - cz);
            np += 1;
        }
    }
    for (m.decor[0..m.decor_count]) |d| {
        if (s.contains(d.Pos.x, d.Pos.z)) {
            clipDecor[nd] = d;
            clipDecor[nd].Pos = v3(d.Pos.x - cx, 0, d.Pos.z - cz);
            nd += 1;
        }
    }
    for (m.packList()) |pk| {
        if (s.contains(pk.x, pk.z)) {
            clipPacks[npk] = pk;
            clipPacks[npk].x = pk.x - cx;
            clipPacks[npk].z = pk.z - cz;
            npk += 1;
        }
    }
    if (np + nd + npk == 0) return ed.status("selection is empty", .{});
    clipPropN = np;
    clipDecorN = nd;
    clipPackN = npk;
    clipHas = true;
    if (cut) deleteSelection(g);
    ed.status("{s} {d} props, {d} decor, {d} packs", .{ if (cut) @as([]const u8, "cut") else "copied", clipPropN, clipDecorN, clipPackN });
}

fn deleteSelection(g: *Game) void {
    const ed = &g.ed;
    const s = ed.sel orelse return ed.status("nothing selected (Shift+drag)", .{});
    // Snapshot first, bank only if something is actually removed — an empty rect must
    // not push a no-op undo frame (evicting real history) or raise a spurious dirty flag.
    const before = g.map;
    const m = &g.map;
    var changed = false;
    var i: usize = m.obstacle_count;
    while (i > 0) {
        i -= 1;
        if (s.contains(m.obstacles[i].Pos.x, m.obstacles[i].Pos.z)) {
            m.removeObstacle(i);
            changed = true;
        }
    }
    i = m.decor_count;
    while (i > 0) {
        i -= 1;
        if (s.contains(m.decor[i].Pos.x, m.decor[i].Pos.z)) {
            m.removeDecor(i);
            changed = true;
        }
    }
    i = m.pack_count;
    while (i > 0) {
        i -= 1;
        if (s.contains(m.packs[i].x, m.packs[i].z)) {
            m.removePack(i);
            changed = true;
        }
    }
    if (!changed) return;
    pushUndoFrom(&before);
    markDirty(g);
}

// Paste the clipboard centered on `at`, clamped into the arena; items past a cap
// are dropped (reported, never silent).
fn pasteAt(g: *Game, at: rl.Vector3) void {
    const ed = &g.ed;
    if (!clipHas) return ed.status("clipboard is empty (Ctrl+C first)", .{});
    bankUndo(g);
    const m = &g.map;
    var dropped: usize = 0;
    for (clipProps[0..clipPropN]) |o| {
        if (m.obstacle_count >= world.MAX_OBSTACLES) {
            dropped += 1;
            continue;
        }
        m.obstacles[m.obstacle_count] = o;
        m.obstacles[m.obstacle_count].Pos = clampContent(m, v3(at.x + o.Pos.x, 0, at.z + o.Pos.z));
        m.obstacle_count += 1;
    }
    for (clipDecor[0..clipDecorN]) |d| {
        if (m.decor_count >= world.MAX_DECOR) {
            dropped += 1;
            continue;
        }
        m.decor[m.decor_count] = d;
        m.decor[m.decor_count].Pos = clampContent(m, v3(at.x + d.Pos.x, 0, at.z + d.Pos.z));
        m.decor_count += 1;
    }
    for (clipPacks[0..clipPackN]) |pk| {
        if (m.pack_count >= mapmod.MAX_PACKS) {
            dropped += 1;
            continue;
        }
        const pp = clampContent(m, v3(at.x + pk.x, 0, at.z + pk.z));
        m.packs[m.pack_count] = pk;
        m.packs[m.pack_count].x = pp.x;
        m.packs[m.pack_count].z = pp.z;
        m.pack_count += 1;
    }
    markDirty(g);
    if (dropped > 0) {
        ed.status("pasted (dropped {d}: limits)", .{dropped});
    } else {
        ed.status("pasted", .{});
    }
}

// Shift the selection's contents by delta, and the rect with it. Membership is
// re-evaluated against the PRE-move rect each step; per-frame deltas are tiny, so
// contents and rect travel together.
fn moveSelection(g: *Game, delta: rl.Vector3) void {
    const ed = &g.ed;
    const s = ed.sel orelse return;
    const m = &g.map;
    for (m.obstacles[0..m.obstacle_count]) |*o| {
        if (s.contains(o.Pos.x, o.Pos.z)) o.Pos = clampContent(m, v3(o.Pos.x + delta.x, o.Pos.y, o.Pos.z + delta.z));
    }
    for (m.decor[0..m.decor_count]) |*d| {
        if (s.contains(d.Pos.x, d.Pos.z)) d.Pos = clampContent(m, v3(d.Pos.x + delta.x, d.Pos.y, d.Pos.z + delta.z));
    }
    for (m.packs[0..m.pack_count]) |*pk| {
        if (s.contains(pk.x, pk.z)) {
            const pp = clampContent(m, v3(pk.x + delta.x, 0, pk.z + delta.z));
            pk.x = pp.x;
            pk.z = pp.z;
        }
    }
    ed.sel = .{
        .minX = s.minX + delta.x,
        .minZ = s.minZ + delta.z,
        .maxX = s.maxX + delta.x,
        .maxZ = s.maxZ + delta.z,
    };
    markDirty(g);
}

// Floor erase: remove the terrain feature whose rect contains the click.
fn eraseFeatureAt(g: *Game, p: rl.Vector3) bool {
    const m = &g.map;
    for (m.ramps[0..m.ramp_count], 0..) |r, i| {
        if (r.contains(p.x, p.z)) {
            m.removeRamp(i);
            markDirty(g);
            return true;
        }
    }
    for (m.ledges[0..m.ledge_count], 0..) |l, i| {
        if (l.contains(p.x, p.z)) {
            m.removeLedge(i);
            markDirty(g);
            return true;
        }
    }
    return false;
}

fn finishDrag(g: *Game, a: rl.Vector3, b: rl.Vector3) bool {
    const ed = &g.ed;
    const m = &g.map;
    // Corners clamp independently (clampContents' limits): a rect past the wall
    // shrinks to fit, one under the min span is rejected.
    const s = normRect(clampContent(m, a), clampContent(m, b));
    const minX = s.minX;
    const maxX = s.maxX;
    const minZ = s.minZ;
    const maxZ = s.maxZ;
    if (maxX - minX < FEATURE_MIN_SPAN or maxZ - minZ < FEATURE_MIN_SPAN) {
        ed.status("drag a bigger rectangle", .{});
        return false;
    }
    switch (ed.floorBrush()) {
        .ledge => {
            if (m.ledge_count >= world.MAX_LEDGES) {
                ed.status("ledge limit reached", .{});
                return false;
            }
            m.ledges[m.ledge_count] = .{ .minX = minX, .maxX = maxX, .minZ = minZ, .maxZ = maxZ, .h = ed.featureH };
            m.ledge_count += 1;
        },
        .ramp => {
            if (m.ramp_count >= world.MAX_RAMPS) {
                ed.status("ramp limit reached", .{});
                return false;
            }
            m.ramps[m.ramp_count] = .{ .minX = minX, .maxX = maxX, .minZ = minZ, .maxZ = maxZ, .h = ed.featureH, .rise = ed.rise };
            m.ramp_count += 1;
        },
        .erase => return false,
    }
    markDirty(g);
    return true;
}

// One paint-stroke step: place/erase at the swept point, respecting per-brush
// spacing so a sweep lays a trail, not a solid wall.
fn paintStep(g: *Game, raw: rl.Vector3) void {
    const ed = &g.ed;
    switch (ed.layer) {
        .props => {
            if (ed.isEraseBrush()) {
                if (eraseWithin(g, raw, ed.brushR)) ed.strokeChanged = true;
                return;
            }
            const tp = toolPoint(ed, raw);
            if (distXZ(tp, ed.lastPaint) < 1.9) return;
            if (placeProp(g, tp)) {
                ed.strokeChanged = true;
                ed.lastPaint = tp;
                if (wantMirror(ed, tp)) _ = placeProp(g, mirrorOf(tp));
                markDirty(g);
            }
        },
        .decor => {
            if (ed.isEraseBrush()) {
                if (eraseWithin(g, raw, ed.brushR)) ed.strokeChanged = true;
                return;
            }
            if (distXZ(raw, ed.lastPaint) < 0.8) return;
            // Jitter within brush radius: a sweep scatters, not strings.
            const j = v3(
                raw.x + (g.rng.float() - 0.5) * ed.brushR,
                0,
                raw.z + (g.rng.float() - 0.5) * ed.brushR,
            );
            if (placeDecor(g, j)) {
                ed.strokeChanged = true;
                ed.lastPaint = raw;
                if (wantMirror(ed, j)) _ = placeDecor(g, mirrorOf(j));
                markDirty(g);
            }
        },
        .entities => {
            if (ed.entityBrush() == .erase) {
                if (eraseWithin(g, raw, ed.brushR)) ed.strokeChanged = true;
            }
        },
        .floor => {},
    }
}

// Author-time scatter brush: repopulate the decor list over open floor. The ONLY
// generator left in the game, and it writes into the map file.
fn scatterDecor(g: *Game) void {
    bankUndo(g);
    const m = &g.map;
    m.decor_count = 0;
    const target: usize = @min(@as(usize, @intFromFloat((m.halfW + m.halfD) * 2.25)), world.MAX_DECOR);
    var placed: usize = 0;
    var attempt: usize = 0;
    while (placed < target and attempt < target * 8) : (attempt += 1) {
        const x = (g.rng.float() * 2 - 1) * (m.halfW - 2);
        const z = (g.rng.float() * 2 - 1) * (m.halfD - 2);
        if (g.w.blocked(v3(x, 0, z), 0.3)) continue;
        if (g.w.onFeature(x, z)) continue;
        const roll = g.rng.float();
        // Tripwire: this weight chain names every DecorKind. A new variant would fold
        // silently into the `.bone` tail and never scatter, so force a revisit here.
        comptime std.debug.assert(@typeInfo(world.DecorKind).@"enum".fields.len == 4);
        const kind: world.DecorKind = if (roll < 0.36) .pebble else if (roll < 0.8) .tuft else if (roll < 0.92) .shroom else .bone;
        m.decor[placed] = .{ .Kind = kind, .Pos = v3(x, 0, z), .Size = decorSize(kind, g.rng.float()) };
        placed += 1;
        m.decor_count = placed;
    }
    g.ed.status("scattered {d} decor", .{placed});
    markDirty(g);
}

fn saveCurrent(g: *Game) void {
    const ed = &g.ed;
    if (ed.path_len == 0) {
        openModal(ed, .save_as);
        return;
    }
    mapmod.save(&g.map, ed.path()) catch {
        ed.status("SAVE FAILED: {s}", .{ed.path()});
        // The confirm modal that may have armed `pending` is already closed, so a
        // stranded action would fire on the NEXT successful save. Abandon it here.
        ed.pending = .none;
        return;
    };
    ed.dirty = false;
    clearRecovery();
    ed.status("saved {s}", .{ed.path()});
    resumePending(g);
}

fn openModal(ed: *Editor, m: Modal) void {
    ed.modal = m;
    ed.field_len = 0;
}

// After a confirm-modal Save/Discard, carry out the guarded action.
fn resumePending(g: *Game) void {
    const ed = &g.ed;
    const act = ed.pending;
    ed.pending = .none;
    switch (act) {
        .none => {},
        .open => doOpen(g, ed.pendingOpen),
        .new => openModal(ed, .new_map),
        .exit => {
            clearRecovery();
            g.scene = .menu;
            ed.modal = .none;
        },
    }
}

// Guard an action behind the unsaved-changes confirm when dirty.
fn requestAction(g: *Game, act: Pending, openIdx: usize) void {
    const ed = &g.ed;
    ed.pendingOpen = openIdx;
    if (ed.dirty) {
        ed.pending = act;
        ed.modal = .confirm;
    } else {
        ed.pending = act;
        resumePending(g);
    }
}

fn doOpen(g: *Game, idx: usize) void {
    const ed = &g.ed;
    resetTransient(g); // no gesture straddles two maps
    g.areaIndex = @min(idx, if (g.mapCount == 0) 0 else g.mapCount - 1);
    g.map = g.loadMapAt(g.areaIndex);
    apply(g);
    ed.camTarget = g.map.spawn;
    g.rig.snap(ed.camTarget);
    ed.dirty = false;
    ed.modal = .none;
    ed.ctxOpen = false;
    ed.setPath(g.currentMapPath());
    clearHistory();
    ed.status("editing {s}", .{g.map.name.slice()});
}

fn doNew(g: *Game) void {
    const ed = &g.ed;
    resetTransient(g); // no gesture straddles two maps
    g.map = mapmod.defaultMap();
    g.map.halfW = ed.newHalfW;
    g.map.halfD = ed.newHalfD;
    if (ed.field_len > 0) g.map.name.set(ed.field_buf[0..ed.field_len]);
    g.map.spawn = v3(0, 0, ed.newHalfD - mapmod.SPAWN_INSET);
    g.map.portal = v3(0, 0, -(ed.newHalfD - mapmod.PORTAL_INSET));
    g.map.bossPos = v3(0, 0, -(ed.newHalfD - mapmod.BOSS_INSET));
    g.map.pack_count = 0;
    apply(g);
    ed.camTarget = g.map.spawn;
    g.rig.snap(ed.camTarget);
    ed.path_len = 0; // unsaved: Ctrl+S will ask for a name
    ed.dirty = true;
    ed.modal = .none;
    clearHistory();
    ed.status("new map - Ctrl+S to name it", .{});
}

// Filename sanitizer shared by Save As commit AND its live preview, so the path
// shown is exactly the path written.
fn slugTo(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    for (src) |c| {
        if (n >= dst.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            dst[n] = std.ascii.toLower(c);
            n += 1;
        } else if ((c == ' ' or c == '_' or c == '-') and n > 0 and dst[n - 1] != '_') {
            dst[n] = '_';
            n += 1;
        }
    }
    return dst[0..n];
}

fn doSaveAs(g: *Game) void {
    const ed = &g.ed;
    if (ed.field_len == 0) return ed.status("give it a file name", .{});
    var buf: [mapmod.PATH_CAP]u8 = undefined;
    var slug: [40]u8 = undefined;
    const s = slugTo(&slug, ed.field_buf[0..ed.field_len]);
    if (s.len == 0) return ed.status("give it a usable file name", .{});
    const p = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ mapmod.dir, s, mapmod.ext }) catch return;
    mapmod.save(&g.map, p) catch {
        ed.status("SAVE FAILED: {s}", .{p});
        return;
    };
    ed.setPath(p);
    ed.dirty = false;
    ed.modal = .none;
    clearRecovery();
    // Campaign may have gained a file: rescan and point areaIndex at it.
    g.mapCount = mapmod.listCampaign(&g.mapPaths, &g.mapPathLens);
    g.lastArea = if (g.mapCount > 0) g.mapCount - 1 else 0;
    for (0..g.mapCount) |i| {
        if (std.mem.eql(u8, g.mapPaths[i][0..g.mapPathLens[i]], p)) g.areaIndex = i;
    }
    ed.status("saved {s}", .{p});
    resumePending(g);
}

// ---- Per-frame update (world-side input; chrome input lives in drawOverlay) ----

pub fn update(g: *Game, dt: f32) void {
    const ed = &g.ed;
    if (ed.status_t > 0) ed.status_t -= dt;

    // Crash-recovery autosave: while dirty, snapshot every REC_INTERVAL s to a side
    // file that never shadows the real map (cleared on save/exit).
    if (ed.dirty) {
        ed.recovT += dt;
        if (ed.recovT >= REC_INTERVAL) {
            ed.recovT = 0;
            mapmod.save(&g.map, REC_PATH) catch {};
        }
    } else ed.recovT = 0;

    // A modal owns ALL input except its own keys (handled by the overlay).
    if (ed.modal != .none) {
        releaseGrab(g); // a modal opened mid pack-drag must not leave the grab armed
        if (rl.isKeyPressed(.escape)) {
            // Esc = cancel: the pack modal edits live state, so restore it.
            if (ed.modal == .pack_edit) g.map = packEditBefore;
            ed.modal = .none;
            // Clear pending, or a stale action fires on the NEXT successful save.
            ed.pending = .none;
        }
        return;
    }

    const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
    const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
    const alt = freePlace();

    // Camera: WASD pans (not while Ctrl-chording, or Ctrl+S would lurch south);
    // RIGHT-DRAG grabs the ground and drags it (right button never deletes); wheel zooms.
    var pan = mathx.zero3;
    if (!ctrl) {
        if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) pan.z -= 1;
        if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) pan.z += 1;
        if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) pan.x -= 1;
        if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) pan.x += 1;
    }
    const speed = 26.0 / g.rig.zoom;
    setCamTarget(g, ed.camTarget.x + pan.x * speed * dt, ed.camTarget.z + pan.z * speed * dt);
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and !ed.uiHot) g.rig.addZoom(wheel);

    if (rl.isMouseButtonPressed(.right)) {
        ed.panAnchor = mousePoint(g);
        ed.rightStart = rl.getMousePosition();
        ed.rightMoved = false;
    }
    var panning = false;
    if (rl.isMouseButtonDown(.right)) {
        const mp = rl.getMousePosition();
        if (!ed.rightMoved and (@abs(mp.x - ed.rightStart.x) > RIGHT_DRAG_PX or @abs(mp.y - ed.rightStart.y) > RIGHT_DRAG_PX)) ed.rightMoved = true;
        if (ed.rightMoved) {
            if (ed.panAnchor) |anchor| {
                if (mousePoint(g)) |cur| {
                    setCamTarget(g, ed.camTarget.x - (cur.x - anchor.x), ed.camTarget.z - (cur.z - anchor.z));
                    panning = true;
                }
            }
        }
    }
    if (rl.isMouseButtonReleased(.right)) {
        if (!ed.rightMoved and !ed.uiHot) {
            if (mousePoint(g)) |p| {
                ed.ctxOpen = true;
                ed.ctxAt = rl.getMousePosition();
                ed.ctxWorld = p;
            }
        }
        ed.panAnchor = null;
    }
    // While the ground is GRABBED, track rigidly: the smoothed follow lags, so each
    // frame's re-pick overshoots and the correction reads as jitter. Snap while
    // dragging, glide otherwise.
    if (panning) g.rig.snap(ed.camTarget) else g.rig.follow(ed.camTarget, dt);

    // Layers: Tab cycles (Shift reverses), Alt+1..N jumps.
    if (rl.isKeyPressed(.tab)) {
        const n: i32 = Layer.N;
        const cur: i32 = @intFromEnum(ed.layer);
        ed.layer = @enumFromInt(@mod(cur + (if (shift) @as(i32, -1) else 1) + n, n));
        ed.status("layer: {s}", .{ed.layer.label()});
    }
    // Brushes: plain 1..9 within the layer; Alt+first-N jump layers instead.
    const numKeys = [_]rl.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
    for (numKeys, 0..) |k, i| {
        if (rl.isKeyPressed(k)) {
            if (alt and i < Layer.N) {
                ed.layer = @enumFromInt(i);
                ed.status("layer: {s}", .{ed.layer.label()});
            } else if (!alt and i < brushesFor(ed.layer).len) {
                ed.setBrush(i);
            }
        }
    }
    if (rl.isKeyPressed(.q) or rl.isKeyPressed(.e)) {
        const n = brushesFor(ed.layer).len;
        const d: i32 = if (rl.isKeyPressed(.e)) 1 else -1;
        const cur: i32 = @intCast(ed.brush());
        ed.setBrush(@intCast(@mod(cur + d, @as(i32, @intCast(n)))));
    }
    if (rl.isKeyPressed(.r) and !ctrl) { // Ctrl+R is recovery-restore, not rise
        ed.rise = @enumFromInt((@intFromEnum(ed.rise) + 1) % @typeInfo(world.RampRise).@"enum".fields.len);
        ed.status("ramp rises {s}", .{@tagName(ed.rise)});
    }
    if (rl.isKeyPressed(.m)) {
        ed.mirrorX = !ed.mirrorX;
        ed.status("mirror-X {s}", .{if (ed.mirrorX) @as([]const u8, "ON") else "off"});
    }
    // [ ] tune the layer's live parameter: feature height on Floor, brush radius elsewhere.
    if (rl.isKeyPressed(.left_bracket)) {
        if (ed.layer == .floor) {
            ed.featureH = clampF(ed.featureH - FEATURE_H_STEP, FEATURE_H_MIN, FEATURE_H_MAX);
            ed.status("feature height {d:.1}", .{ed.featureH});
        } else {
            ed.brushR = clampF(ed.brushR - BRUSH_R_STEP, BRUSH_R_MIN, BRUSH_R_MAX);
            ed.status("brush {d:.1}", .{ed.brushR});
        }
    }
    if (rl.isKeyPressed(.right_bracket)) {
        if (ed.layer == .floor) {
            ed.featureH = clampF(ed.featureH + FEATURE_H_STEP, FEATURE_H_MIN, FEATURE_H_MAX);
            ed.status("feature height {d:.1}", .{ed.featureH});
        } else {
            ed.brushR = clampF(ed.brushR + BRUSH_R_STEP, BRUSH_R_MIN, BRUSH_R_MAX);
            ed.status("brush {d:.1}", .{ed.brushR});
        }
    }
    if (rl.isKeyPressed(.g)) ed.grid = !ed.grid;
    if (rl.isKeyPressed(.x) and !ctrl and ed.layer == .decor) scatterDecor(g); // Decor-only, matches Scatter button (Ctrl+X is cut)

    if (ctrl and shift and rl.isKeyPressed(.s)) {
        openModal(ed, .save_as);
    } else if (ctrl and rl.isKeyPressed(.s)) saveCurrent(g);
    if (ctrl and rl.isKeyPressed(.o)) openModal(ed, .open_map);
    if (ctrl and rl.isKeyPressed(.n)) requestAction(g, .new, 0);
    if (ctrl and rl.isKeyPressed(.z)) {
        if (shift) doRedo(g) else doUndo(g);
    }
    if (ctrl and rl.isKeyPressed(.y)) doRedo(g);
    if (ctrl and rl.isKeyPressed(.c)) copySelection(g, false);
    if (ctrl and rl.isKeyPressed(.x)) copySelection(g, true);
    if (ctrl and rl.isKeyPressed(.v)) {
        if (mousePoint(g)) |p| pasteAt(g, p);
    }
    if (rl.isKeyPressed(.delete)) deleteSelection(g);
    if (ctrl and rl.isKeyPressed(.r) and recoveryExists()) {
        if (mapmod.load(REC_PATH)) |m| {
            resetTransient(g); // no gesture straddles the map swap (mirrors doOpen)
            g.map = m;
            apply(g);
            ed.dirty = true;
            clearHistory();
            ed.status("recovered autosave - Ctrl+S to keep it", .{});
        } else |_| {
            ed.status("recovery file is unreadable", .{});
        }
    }

    if (rl.isKeyPressed(.home)) {
        ed.camTarget = g.map.spawn;
        g.rig.zoom = cameramod.DEFAULT_ZOOM;
        g.rig.snap(ed.camTarget);
    }
    if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) g.rig.addZoom(1);
    if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) g.rig.addZoom(-1);

    if (rl.isKeyPressed(.f5)) {
        resetTransient(g); // no armed grab/stroke/marquee survives the round-trip
        // Ctrl+F5: playtest FROM THE CURSOR instead of the spawn.
        if (ctrl) {
            if (mousePoint(g)) |p| {
                gamemod.startPlaytestAt(g, clampAnchor(&g.map, p));
                return;
            }
        }
        gamemod.startPlaytest(g);
        return;
    }
    if (rl.isKeyPressed(.escape)) {
        if (ed.ctxOpen) {
            ed.ctxOpen = false;
            return;
        }
        if (ed.sel != null or ed.selDrag != null) {
            ed.sel = null;
            ed.selDrag = null;
            return;
        }
        requestAction(g, .exit, 0);
        return;
    }

    // World interaction — blocked while the pointer is over chrome or a menu. Release
    // every in-flight drag here, or a marquee/stroke ending over a panel stays armed
    // and resumes itself back over the world.
    if (ed.uiHot or ed.ctxOpen) {
        ed.dragStart = null;
        ed.selDrag = null;
        ed.selMove = null;
        if (ed.strokeActive) endStroke(ed);
        releaseGrab(g); // a pack grab dragged onto chrome/a menu releases here too
        return;
    }
    const pt = mousePoint(g);
    if (pt) |p| {
        // ---- Marquee selection owns the mouse while active ----
        if (shift and rl.isMouseButtonPressed(.left)) {
            ed.selDrag = p;
            ed.sel = null;
        }
        if (ed.selDrag) |a| {
            if (rl.isMouseButtonReleased(.left)) {
                const s = normRect(a, p);
                ed.sel = if (s.maxX - s.minX > 1.0 and s.maxZ - s.minZ > 1.0) s else null;
                ed.selDrag = null;
            }
            return;
        }
        if (ed.sel) |s| {
            if (rl.isMouseButtonPressed(.left) and !shift and s.contains(p.x, p.z)) {
                ed.selMove = p;
                selBankPending = true; // bank on the FIRST real move, not the grab
            }
            if (ed.selMove) |last| {
                if (rl.isMouseButtonDown(.left)) {
                    const delta = v3(p.x - last.x, 0, p.z - last.z);
                    if (@abs(delta.x) + @abs(delta.z) > 1e-4) {
                        if (selBankPending) {
                            bankUndo(g);
                            selBankPending = false;
                        }
                        moveSelection(g, delta);
                    }
                    ed.selMove = p;
                }
                if (rl.isMouseButtonReleased(.left)) ed.selMove = null;
                return;
            }
        }

        const tp = toolPoint(ed, p);
        // A layer/brush switch mid-drag (Tab, Alt+N, toolbar) leaves the current
        // case unable to own an in-flight stroke, so its release would never bank
        // undo AND strokeActive would stay set — silently blocking all undo/redo
        // (the doUndo/doRedo gesture guards) until the next stroke overwrites strokeBefore. Close
        // the stroke here the moment the active tool can no longer own it.
        const ownsStroke = switch (ed.layer) {
            .decor, .props => true,
            .entities => ed.entityBrush() == .erase,
            else => false,
        };
        if (ed.strokeActive and !ownsStroke) endStroke(ed);
        // Symmetric teardown for the floor rect-drag, which only the .floor case owns:
        // a layer switch mid-drag must drop the anchor too, or its ghost preview lingers
        // on the new layer and a later floor release (after tabbing back, LMB still held)
        // commits a feature from the stale anchor.
        if (ed.dragStart != null and ed.layer != .floor) ed.dragStart = null;
        switch (ed.layer) {
            .floor => {
                if (rl.isMouseButtonPressed(.left)) {
                    if (ed.isEraseBrush()) {
                        const before = g.map;
                        if (eraseFeatureAt(g, p)) pushUndoFrom(&before);
                    } else ed.dragStart = tp;
                }
                if (rl.isMouseButtonReleased(.left)) {
                    if (ed.dragStart) |a| {
                        const before = g.map;
                        if (finishDrag(g, a, tp)) pushUndoFrom(&before);
                        ed.dragStart = null;
                    }
                }
            },
            .decor, .props => {
                if (rl.isMouseButtonPressed(.left)) {
                    ed.strokeActive = true;
                    ed.strokeChanged = false;
                    strokeBefore = g.map;
                    ed.lastPaint = v3(1e9, 0, 1e9);
                }
                if (ed.strokeActive and rl.isMouseButtonDown(.left)) paintStep(g, p);
                if (rl.isMouseButtonReleased(.left) and ed.strokeActive) endStroke(ed);
            },
            .entities => switch (ed.entityBrush()) {
                .pack => {
                    if (rl.isMouseButtonPressed(.left)) {
                        // Press ON an existing pack grabs it (drag to move, release
                        // in place to edit) instead of stamping another.
                        for (g.map.packs[0..g.map.pack_count], 0..) |pk, i| {
                            if (distXZ(pk.pos(), p) < PACK_GRAB_R) {
                                ed.grabIdx = i;
                                ed.grabStart = p;
                                packEditBefore = g.map;
                                break;
                            }
                        }
                        if (ed.grabIdx == null) {
                            const before = g.map;
                            if (placePack(g, tp)) {
                                if (wantMirror(ed, tp)) _ = placePack(g, mirrorOf(tp));
                                markDirty(g);
                                pushUndoFrom(&before);
                            }
                        }
                    }
                    if (ed.grabIdx) |gi| {
                        if (rl.isMouseButtonDown(.left)) {
                            const cp = clampContent(&g.map, tp); // a drag can leave the arena
                            g.map.packs[gi].x = cp.x;
                            g.map.packs[gi].z = cp.z;
                        }
                        if (rl.isMouseButtonReleased(.left)) {
                            if (distXZ(p, ed.grabStart) < 0.6) {
                                // Released in place: no move — edit it instead.
                                g.map = packEditBefore;
                                ed.packEditIdx = gi;
                                ed.modal = .pack_edit;
                            } else {
                                pushUndoFrom(&packEditBefore);
                                ed.dirty = true;
                            }
                            ed.grabIdx = null;
                        }
                    }
                },
                .boss, .spawn, .portal => {
                    if (rl.isMouseButtonPressed(.left)) {
                        bankUndo(g);
                        const ap = clampAnchor(&g.map, tp); // anchors use the deeper inset
                        switch (ed.entityBrush()) {
                            .boss => g.map.bossPos = v3(ap.x, 0, ap.z),
                            .spawn => g.map.spawn = v3(ap.x, 0, ap.z),
                            .portal => g.map.portal = v3(ap.x, 0, ap.z),
                            else => {},
                        }
                        markDirty(g);
                    }
                },
                .erase => {
                    if (rl.isMouseButtonPressed(.left)) {
                        ed.strokeActive = true;
                        ed.strokeChanged = false;
                        strokeBefore = g.map;
                    }
                    if (ed.strokeActive and rl.isMouseButtonDown(.left)) paintStep(g, p);
                    if (rl.isMouseButtonReleased(.left) and ed.strokeActive) endStroke(ed);
                },
            },
        }
    } else if (rl.isMouseButtonReleased(.left)) {
        // The pick can fail mid-gesture (a cliff face returns no ground point): a
        // release there must still tear down like the chrome path above, or the armed
        // grab/marquee/stroke replays on the next press and its undo banking is lost.
        ed.dragStart = null;
        ed.selDrag = null;
        ed.selMove = null;
        if (ed.strokeActive) endStroke(ed);
        releaseGrab(g);
    }
}

fn endStroke(ed: *Editor) void {
    if (ed.strokeChanged) pushUndoFrom(&strokeBefore);
    ed.strokeActive = false;
    ed.strokeChanged = false;
}

// Close out every in-flight gesture (rect drag, stroke, grab, marquee, pan) so
// nothing stays armed across a map swap or playtest round-trip: a grab/selection
// surviving doOpen would act on the NEW map with OLD indices/rect and its snapshot
// would restore the wrong map. Already-committed work banks undo like a release.
fn resetTransient(g: *Game) void {
    const ed = &g.ed;
    ed.dragStart = null;
    ed.panAnchor = null;
    ed.sel = null;
    ed.selDrag = null;
    ed.selMove = null;
    ed.ctxOpen = false; // F5 can playtest with the context menu open; don't let it
    // survive the round-trip and redraw actionable at the stale ctxAt/ctxWorld.
    if (ed.strokeActive) endStroke(ed);
    releaseGrab(g);
}

// Release a pack grab interrupted before its own mouse-up (pointer wandered onto
// chrome/a menu, or a modal opened mid-drag). grabIdx persists across frames, so a
// forgotten early return would leave it armed with the button up and the NEXT click
// would teleport the pack. Commit like a release-with-move, but only if the pack
// actually moved (a bare grab is a no-op: no phantom undo step or dirty flag).
fn releaseGrab(g: *Game) void {
    const ed = &g.ed;
    const gi = ed.grabIdx orelse return;
    ed.grabIdx = null;
    if (gi < g.map.pack_count and !std.meta.eql(g.map.packs[gi], packEditBefore.packs[gi])) {
        pushUndoFrom(&packEditBefore);
        ed.dirty = true;
    }
}

// ---- Drawing (world) ----

// Render the world under an "editor sun": the same torch pipeline, but the light
// hangs high over the camera target with a huge radius, so the whole map is lit and
// shadowed like the game.
pub fn draw(g: *Game) void {
    const ed = &g.ed;
    const cam = g.rig.cam;
    const lp = tl.LightParams{
        .pos = v3(ed.camTarget.x, ed.camTarget.y + EDITOR_SUN_H, ed.camTarget.z),
        .radius = EDITOR_SUN_R,
        .groundRef = ed.camTarget.y,
    };
    const fp = tl.FireParams{ .pos = mathx.zero3, .radius = 1, .color = mathx.zero3, .intensity = 0 };

    g.torch.beginShadowPass(lp);
    g.sceneMesh.drawDepth();
    drawEncounterPreviews(g);
    g.torch.endShadowPass();

    gamemod.beginSceneFrame(g, cam, lp, fp);
    drawEncounterPreviews(g);
    g.torch.endScene();
    gamemod.drawPortal(&g.w, g.elapsed);
    drawMarkers(g);
    rl.endMode3D();
}

// Live monster silhouettes on every pack (in the deploy ring) plus the boss at its
// post, so the ENCOUNTER reads at a glance. Statuesque: no bob, facing outward.
// Drawn in both passes so they cast shadows. makeMonster rolls per-kind cooldowns off
// the rng it's handed, but the drawn (statuesque) body ignores them — so a throwaway
// local rng keeps previews deterministic AND leaves g.rng (author-time scatter/paint
// jitter) unperturbed by every frame's rebuild.
fn drawEncounterPreviews(g: *Game) void {
    var rng = mathx.Rng.init(0);
    for (g.map.packList()) |pk| {
        const c = g.w.snapY(pk.pos());
        const n: i32 = @max(pk.count, 1);
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const a = @as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(n)));
            var mm = monster.makeMonster(pk.kind, 0, &rng, g.w.snapY(v3(c.x + mathx.cosf(a) * 1.1, 0, c.z + mathx.sinf(a) * 1.1)));
            mm.Facing = v3(mathx.cosf(a), 0, mathx.sinf(a));
            gamemod.drawMonsterBody(&mm, false); // editor preview: no target highlight
        }
    }
    var boss = monster.makeBoss(0, g.map.boss.slice(), &rng, g.w.snapY(g.map.bossPos));
    boss.Facing = v3(0, 0, 1);
    gamemod.drawMonsterBody(&boss, false);
}

// rl.drawGrid only draws square grids, so clip GRID-spaced lines to the arena rect
// ourselves. Sits a hair above the floor to avoid z-fighting.
fn drawRectGrid(m: *const mapmod.Map) void {
    const col = rgba(255, 255, 255, 40);
    const y = 0.01;
    var x: f32 = -m.halfW;
    while (x <= m.halfW + 0.01) : (x += GRID) {
        rl.drawLine3D(v3(x, y, -m.halfD), v3(x, y, m.halfD), col);
    }
    var z: f32 = -m.halfD;
    while (z <= m.halfD + 0.01) : (z += GRID) {
        rl.drawLine3D(v3(-m.halfW, y, z), v3(m.halfW, y, z), col);
    }
}

fn drawMarkers(g: *Game) void {
    const ed = &g.ed;
    const m = &g.map;

    if (ed.grid) drawRectGrid(m);

    marker(g, m.spawn, SPAWN_COL, SPAWN_R);
    marker(g, m.portal, PORTAL_COL, PORTAL_R);
    marker(g, m.bossPos, BOSS_COL, BOSS_R);

    // Packs: silhouettes show the encounter; here just the grab ring in the kind's
    // color over a dark puck.
    for (m.packList()) |pk| {
        const col = packColor(pk.kind);
        const c = g.w.snapY(pk.pos());
        rl.drawCylinderEx(v3(c.x, c.y + 0.01, c.z), v3(c.x, c.y + 0.03, c.z), PACK_GRAB_R + 0.3, PACK_GRAB_R + 0.3, 20, withAlpha(theme.ink, 120));
        gamemod.groundRing(v3(c.x, c.y + 0.06, c.z), PACK_GRAB_R, col);
        gamemod.groundRing(v3(c.x, c.y + 0.06, c.z), PACK_GRAB_R - 0.15, withAlpha(col, 150));
    }

    // Marquee: the live drag rect, then the committed one.
    if (ed.selDrag) |a| {
        if (mousePoint(g)) |cur| {
            const s = normRect(a, cur);
            rl.drawCubeWiresV(v3((s.minX + s.maxX) / 2, 0.4, (s.minZ + s.maxZ) / 2), v3(s.maxX - s.minX, 0.8, s.maxZ - s.minZ), rgba(255, 235, 160, 230));
        }
    }
    if (ed.sel) |s| {
        rl.drawCubeWiresV(v3((s.minX + s.maxX) / 2, 0.4, (s.minZ + s.maxZ) / 2), v3(s.maxX - s.minX, 0.8, s.maxZ - s.minZ), rgba(255, 220, 120, 255));
        rl.drawCylinderEx(v3((s.minX + s.maxX) / 2, 0.01, (s.minZ + s.maxZ) / 2), v3((s.minX + s.maxX) / 2, 0.02, (s.minZ + s.maxZ) / 2), 0.3, 0.3, 12, rgba(255, 220, 120, 90));
    }

    // Prop collision circles so spacing reads at a glance.
    for (m.obstacles[0..m.obstacle_count]) |o| {
        gamemod.groundRing(v3(o.Pos.x, g.w.groundY(o.Pos.x, o.Pos.z) + 0.04, o.Pos.z), o.Radius, rgba(255, 255, 255, 50));
    }

    // Live drag rect preview for ledge/ramp (corners snapped like the commit).
    if (ed.dragStart) |a| {
        if (mousePoint(g)) |raw| {
            const s = normRect(a, toolPoint(ed, raw));
            const col = if (ed.floorBrush() == .ledge) rgba(255, 220, 120, 220) else rgba(120, 255, 180, 220);
            rl.drawCubeWiresV(v3((s.minX + s.maxX) / 2, ed.featureH / 2, (s.minZ + s.maxZ) / 2), v3(s.maxX - s.minX, ed.featureH, s.maxZ - s.minZ), col);
        }
    }

    // Cursor aids hide while a marquee owns the mouse (they'd fight the rect).
    if (!ed.uiHot and !ed.ctxOpen and ed.selDrag == null and ed.selMove == null) drawCursorAids(g);
}

// Cursor affordances: snapped puck + cell, erase circle with its victims
// highlighted pre-commit, and the mirror twin when mirroring.
fn drawCursorAids(g: *Game) void {
    const ed = &g.ed;
    const raw = mousePoint(g) orelse return;
    const p = toolPoint(ed, raw);

    if (ed.isEraseBrush()) {
        if (ed.layer == .floor) {
            // Highlight the feature rect the click would remove.
            for (g.map.ramps[0..g.map.ramp_count]) |r| {
                if (r.contains(raw.x, raw.z)) {
                    rl.drawCubeWiresV(v3((r.minX + r.maxX) / 2, r.h / 2, (r.minZ + r.maxZ) / 2), v3(r.maxX - r.minX, r.h, r.maxZ - r.minZ), rgba(255, 80, 60, 230));
                }
            }
            for (g.map.ledges[0..g.map.ledge_count]) |l| {
                if (l.contains(raw.x, raw.z)) {
                    rl.drawCubeWiresV(v3((l.minX + l.maxX) / 2, l.h / 2, (l.minZ + l.maxZ) / 2), v3(l.maxX - l.minX, l.h, l.maxZ - l.minZ), rgba(255, 80, 60, 230));
                }
            }
        } else {
            // Sweep circle, plus a ring on everything it would take.
            gamemod.groundRing(v3(raw.x, raw.y + 0.06, raw.z), ed.brushR, rgba(255, 90, 70, 200));
            const m = &g.map;
            switch (ed.layer) {
                .props => for (m.obstacles[0..m.obstacle_count]) |o| {
                    if (distXZ(o.Pos, raw) < ed.brushR) {
                        gamemod.groundRing(v3(o.Pos.x, g.w.groundY(o.Pos.x, o.Pos.z) + 0.08, o.Pos.z), o.Radius + 0.15, rgba(255, 60, 40, 255));
                    }
                },
                .decor => for (m.decor[0..m.decor_count]) |d| {
                    if (distXZ(d.Pos, raw) < ed.brushR) {
                        gamemod.groundRing(v3(d.Pos.x, g.w.groundY(d.Pos.x, d.Pos.z) + 0.08, d.Pos.z), d.Size + 0.2, rgba(255, 60, 40, 255));
                    }
                },
                .entities => for (m.packList()) |pk| {
                    if (distXZ(pk.pos(), raw) < ed.brushR) {
                        const c = g.w.snapY(pk.pos());
                        gamemod.groundRing(v3(c.x, c.y + 0.1, c.z), PACK_GRAB_R + 0.2, rgba(255, 60, 40, 255));
                    }
                },
                .floor => {},
            }
        }
        return;
    }

    gamemod.groundRing(v3(p.x, p.y + 0.05, p.z), 0.5, rgba(255, 245, 200, 200));
    if (p.x != raw.x or p.z != raw.z) {
        const c = snapCenter(raw);
        rl.drawCubeWiresV(v3(c.x, p.y + 0.03, c.z), v3(GRID, 0.0, GRID), rgba(255, 245, 200, 120));
    }
    if (wantMirror(ed, p)) {
        const mp = mirrorOf(p);
        gamemod.groundRing(v3(mp.x, g.w.groundY(mp.x, mp.z) + 0.05, mp.z), 0.5, rgba(160, 220, 255, 160));
    }
}

fn marker(g: *Game, at: rl.Vector3, col: rl.Color, r: f32) void {
    const p = g.w.snapY(at);
    // Dark puck + doubled ring + a tall haloed banner post: the map's fixed anchors,
    // never to be lost against the terrain.
    rl.drawCylinderEx(v3(p.x, p.y + 0.01, p.z), v3(p.x, p.y + 0.03, p.z), r + 0.35, r + 0.35, 20, withAlpha(theme.ink, 150));
    gamemod.groundRing(v3(p.x, p.y + 0.06, p.z), r, col);
    gamemod.groundRing(v3(p.x, p.y + 0.06, p.z), r - 0.14, withAlpha(col, 150));
    rl.drawCylinderEx(v3(p.x, p.y, p.z), v3(p.x, p.y + 2.6, p.z), 0.1, 0.03, 6, col);
    rl.drawSphereEx(v3(p.x, p.y + 2.75, p.z), 0.26, 8, 8, col);
    rl.drawSphereEx(v3(p.x, p.y + 2.75, p.z), 0.42, 8, 8, withAlpha(col, 70));
}

fn packColor(k: monster.MonsterKind) rl.Color {
    return switch (k) {
        .fallen => rgba(220, 110, 90, 255),
        .zombie => rgba(120, 170, 100, 255),
        .skeleton => rgba(230, 230, 205, 255),
        .brute => rgba(200, 110, 170, 255),
    };
}

// ---- Chrome (2D widgets, after endMode3D) ----

const TOPBAR_H = 40;
const PALETTE_W = 148;
const PANEL_W = 224;
const MM_S = 150; // minimap side
const LAYER_ROW_H = 30; // stride of a layer/brush button row
const STEP_ROW_H = 28; // vertical stride of a property/stepper row in the panels

pub fn drawOverlay(g: *Game) void {
    const ed = &g.ed;
    var ctx = ui.Ctx.begin();
    const W = rl.getScreenWidth();
    const H = rl.getScreenHeight();

    // A modal owns the pointer WHOLESALE, but immediate-mode chrome under it hit-tests
    // as it draws this same frame: silence the mouse for those widgets or Undo/
    // Playtest/steppers fire through the backdrop and desync packEditBefore.
    const modalOpen = ed.modal != .none;
    const livePressed = ctx.pressed;
    const liveDown = ctx.down;
    if (modalOpen) {
        ctx.pressed = false;
        ctx.down = false;
    }
    drawTopbar(g, &ctx, W);
    drawPalette(g, &ctx);
    drawProperties(g, &ctx, W);
    drawMinimap(g, &ctx, W, H);
    drawStatusBar(g, &ctx, W, H);
    drawContextMenu(g, &ctx);
    if (modalOpen) {
        ctx.pressed = livePressed;
        ctx.down = liveDown;
    }
    drawModal(g, &ctx);
    hoverWorldTip(g, &ctx);
    ui.drawTip(&ctx); // whatever earned a tooltip this frame, drawn over it all

    // Chrome owns the pointer wherever a widget was hot; world input reads this next
    // frame (one-frame lag, imperceptible).
    ed.uiHot = ctx.anyHot;
}

// When the pointer is over the WORLD, name what's under it: packs, anchors, props,
// decor, terrain.
fn hoverWorldTip(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    if (ctx.anyHot or ed.modal != .none or ed.ctxOpen) return;
    // Tips only at rest: mid-paint/drag they'd flicker under the brush.
    if (rl.isMouseButtonDown(.left) or rl.isMouseButtonDown(.right)) return;
    const p = mousePoint(g) orelse return;
    var buf: [ui.MSG_CAP]u8 = undefined;
    const m = &g.map;
    for (m.packList()) |pk| {
        if (distXZ(pk.pos(), p) < PACK_GRAB_R) {
            const s = std.fmt.bufPrint(&buf, "{s} pack x{d} - grab to move, click in place to edit", .{ @tagName(pk.kind), pk.count }) catch return;
            ctx.setTip(s);
            return;
        }
    }
    if (distXZ(m.bossPos, p) < BOSS_R + MARKER_HOVER_PAD) {
        const s = std.fmt.bufPrint(&buf, "Boss post: {s}", .{m.boss.slice()}) catch return;
        ctx.setTip(s);
        return;
    }
    if (distXZ(m.spawn, p) < SPAWN_R + MARKER_HOVER_PAD) return ctx.setTip("Spawn - where the hero enters");
    if (distXZ(m.portal, p) < PORTAL_R + MARKER_HOVER_PAD) return ctx.setTip("Portal - the area exit");
    for (m.obstacles[0..m.obstacle_count]) |o| {
        if (distXZ(o.Pos, p) < o.Radius + 0.3) {
            const s = std.fmt.bufPrint(&buf, "{s} (Props layer)", .{@tagName(o.Kind)}) catch return;
            ctx.setTip(s);
            return;
        }
    }
    for (m.decor[0..m.decor_count]) |d| {
        if (distXZ(d.Pos, p) < 0.6) {
            const s = std.fmt.bufPrint(&buf, "{s} (Decor layer)", .{@tagName(d.Kind)}) catch return;
            ctx.setTip(s);
            return;
        }
    }
    for (m.ramps[0..m.ramp_count]) |r| {
        if (r.contains(p.x, p.z)) {
            const s = std.fmt.bufPrint(&buf, "ramp h {d:.1} rises {s} - RMB to re-height", .{ r.h, @tagName(r.rise) }) catch return;
            ctx.setTip(s);
            return;
        }
    }
    for (m.ledges[0..m.ledge_count]) |l| {
        if (l.contains(p.x, p.z)) {
            const s = std.fmt.bufPrint(&buf, "ledge h {d:.1} - RMB to re-height", .{l.h}) catch return;
            ctx.setTip(s);
            return;
        }
    }
}

fn drawTopbar(g: *Game, ctx: *ui.Ctx, W: i32) void {
    const ed = &g.ed;
    ui.claimedPanel(ctx, ui.rect(0, 0, W, TOPBAR_H), null); // dead space is still chrome
    var x: i32 = 8;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 54, 26), "New", 17, false, "Start a blank map (Ctrl+N)")) requestAction(g, .new, 0);
    x += 60;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 60, 26), "Open", 17, false, "Open a campaign map (Ctrl+O)")) openModal(ed, .open_map);
    x += 66;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 58, 26), "Save", 17, false, "Save to its file, .bak kept (Ctrl+S)")) saveCurrent(g);
    x += 64;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 84, 26), "Save As", 17, false, "Save under a new file name (Ctrl+Shift+S)")) openModal(ed, .save_as);
    x += 90;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 62, 26), "Undo", 17, false, "Undo the last edit (Ctrl+Z)")) doUndo(g);
    x += 68;
    if (ui.buttonTip(ctx, ui.rect(x, 7, 62, 26), "Redo", 17, false, "Redo (Ctrl+Y)")) doRedo(g);
    x += 74;

    var nameBuf: [72]u8 = undefined;
    const nm = std.fmt.bufPrintZ(&nameBuf, "{s}{s}", .{ g.map.name.slice(), if (ed.dirty) " *" else "" }) catch "";
    hudx.text(nm, x + 6, 10, 21, theme.titleColor);

    var rx: i32 = W - 8;
    rx -= 66;
    if (ui.buttonTip(ctx, ui.rect(rx, 7, 66, 26), "Menu", 17, false, "Back to the title (Esc)")) requestAction(g, .exit, 0);
    rx -= 116;
    if (ui.buttonTip(ctx, ui.rect(rx, 7, 110, 26), "Playtest F5", 17, false, "Play this map now - Ctrl+F5 starts at the cursor")) {
        resetTransient(g); // as the F5 key: no armed grab/stroke/marquee survives the round-trip
        gamemod.startPlaytest(g);
    }
}

fn drawPalette(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    const px = 8;
    var y: i32 = TOPBAR_H + 8;

    // LAYERS: the workspace switch (Tab cycles; Alt+1..4 jumps). Height derived from
    // Layer.N so a new layer can't outgrow the panel.
    ui.claimedPanel(ctx, ui.rect(px, y, PALETTE_W, 26 + @as(i32, Layer.N) * LAYER_ROW_H + 6), "LAYERS");
    y += 26;
    inline for (@typeInfo(Layer).@"enum".fields, 0..) |f, li| {
        const l: Layer = @enumFromInt(f.value);
        if (ui.buttonTip(ctx, ui.rect(px + 8, y, PALETTE_W - 16, 26), l.label(), 16, ed.layer == l, layerTips[li])) {
            ed.layer = l;
        }
        y += LAYER_ROW_H;
    }
    y += 8;

    // BRUSHES: active layer's kit, numbered like its hotkeys.
    const brushes = brushesFor(ed.layer);
    const tips = brushTipsFor(ed.layer);
    const extraRows: i32 = if (ed.layer == .decor) 2 else 0;
    const brushesRect = ui.rect(px, y, PALETTE_W, 26 + @as(i32, @intCast(brushes.len)) * LAYER_ROW_H + extraRows * STEP_ROW_H + 6);
    ui.claimedPanel(ctx, brushesRect, "BRUSHES");
    y += 26;
    for (brushes, 0..) |label, i| {
        var kb: [24]u8 = undefined;
        const lbl = std.fmt.bufPrintZ(&kb, "{d}  {s}", .{ i + 1, label }) catch "";
        if (ui.buttonTip(ctx, ui.rect(px + 8, y, PALETTE_W - 16, 26), lbl, 16, ed.brush() == i, tips[i])) ed.setBrush(i);
        y += LAYER_ROW_H;
    }
    if (ed.layer == .decor) {
        if (ui.buttonTip(ctx, ui.rect(px + 8, y, PALETTE_W - 16, 24), "Scatter (X)", 15, false, "Re-roll ALL decor over open floor (undoable)")) scatterDecor(g);
        y += STEP_ROW_H;
        if (ui.buttonTip(ctx, ui.rect(px + 8, y, PALETTE_W - 16, 24), "Clear all", 15, false, "Delete every decor on the map (undoable)")) {
            bankUndo(g);
            g.map.decor_count = 0;
            markDirty(g);
        }
        y += STEP_ROW_H;
    }
}

fn drawProperties(g: *Game, ctx: *ui.Ctx, W: i32) void {
    const ed = &g.ed;
    const px = W - PANEL_W - 8;
    var y: i32 = TOPBAR_H + 8;

    ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 196), "MAP");
    y += 26;
    if (ui.buttonTip(ctx, ui.rect(px + 8, y, PANEL_W - 16, 24), "Rename...", 15, false, "The name shown on the area banner")) openModal(ed, .rename);
    y += 30;
    ui.tipFor(ctx, ui.rect(px + 8, y - 2, PANEL_W - 16, 26), "East-west half-extent; shrinking clamps contents");
    var halfW = g.map.halfW;
    if (ui.stepperF(ctx, px + 10, y, "width", &halfW, HALF_STEP, HALF_MIN, HALF_MAX)) {
        bankUndo(g);
        g.map.halfW = halfW;
        clampContents(&g.map);
        markDirty(g);
    }
    y += STEP_ROW_H;
    ui.tipFor(ctx, ui.rect(px + 8, y - 2, PANEL_W - 16, 26), "North-south half-extent; shrinking clamps contents");
    var halfD = g.map.halfD;
    if (ui.stepperF(ctx, px + 10, y, "depth", &halfD, HALF_STEP, HALF_MIN, HALF_MAX)) {
        bankUndo(g);
        g.map.halfD = halfD;
        clampContents(&g.map);
        markDirty(g);
    }
    y += STEP_ROW_H;
    hudx.text("palette", px + 10, y + 3, 15, withAlpha(theme.labelColor, 230));
    var sx = px + 76;
    for (presets) |p| {
        ui.tipFor(ctx, ui.rect(sx, y, 24, 22), p.name);
        const active = g.map.ground.r == p.ground.r and g.map.ground.g == p.ground.g and g.map.ground.b == p.ground.b;
        if (ui.swatch(ctx, sx, y, 24, 22, p.ground, p.accent, active)) {
            bankUndo(g);
            g.map.ground = p.ground;
            g.map.accent = p.accent;
            g.map.light = p.light;
            markDirty(g);
            ed.status("palette: {s}", .{p.name});
        }
        sx += 28;
    }
    y += 30;
    var counts: [64]u8 = undefined;
    const cs = std.fmt.bufPrintZ(&counts, "props {d}/{d}  decor {d}/{d}", .{ g.map.obstacle_count, world.MAX_OBSTACLES, g.map.decor_count, world.MAX_DECOR }) catch "";
    hudx.text(cs, px + 10, y, 15, rgba(190, 180, 165, 210));
    y += 22;
    var counts2: [64]u8 = undefined;
    const cs2 = std.fmt.bufPrintZ(&counts2, "packs {d}/{d}  ledges {d}  ramps {d}", .{ g.map.pack_count, mapmod.MAX_PACKS, g.map.ledge_count, g.map.ramp_count }) catch "";
    hudx.text(cs2, px + 10, y, 15, rgba(190, 180, 165, 210));
    y += 34;

    // Layer parameters.
    switch (ed.layer) {
        .entities => {
            if (ed.entityBrush() == .pack) {
                ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 62), "PACK");
                ui.tipFor(ctx, ui.rect(px + 8, y + 26, PANEL_W - 16, 26), "Members stamped per new pack");
                _ = ui.stepperI(ctx, px + 10, y + 28, "members", &ed.packCount, PACK_MIN, PACK_MAX);
            } else if (ed.entityBrush() == .erase) {
                ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 62), "ERASE");
                ui.tipFor(ctx, ui.rect(px + 8, y + 26, PANEL_W - 16, 26), "Erase sweep radius ([ ] adjusts)");
                _ = ui.stepperF(ctx, px + 10, y + 28, "radius", &ed.brushR, BRUSH_R_STEP, BRUSH_R_MIN, BRUSH_R_MAX);
            }
        },
        .floor => {
            ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 94), "TERRAIN");
            ui.tipFor(ctx, ui.rect(px + 8, y + 26, PANEL_W - 16, 26), "Height of NEW ledges/ramps; RMB a feature to apply");
            _ = ui.stepperF(ctx, px + 10, y + 28, "height", &ed.featureH, FEATURE_H_STEP, FEATURE_H_MIN, FEATURE_H_MAX);
            if (ed.floorBrush() == .ramp) {
                var used: i32 = 0;
                var cx = px + 10;
                inline for (@typeInfo(world.RampRise).@"enum".fields) |f| {
                    const k: world.RampRise = @enumFromInt(f.value);
                    if (ui.chip(ctx, cx, y + 60, f.name, ed.rise == k, &used)) ed.rise = k;
                    cx += used;
                }
            }
        },
        .decor, .props => {
            ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 62), "BRUSH");
            ui.tipFor(ctx, ui.rect(px + 8, y + 26, PANEL_W - 16, 26), "Brush radius: decor spread + erase sweep ([ ])");
            _ = ui.stepperF(ctx, px + 10, y + 28, "radius", &ed.brushR, BRUSH_R_STEP, BRUSH_R_MIN, BRUSH_R_MAX);
        },
    }
}

// Keep authored anchors AND terrain rects inside a shrunken arena; features that
// collapse below a usable span are dropped, not left as slivers.
fn clampContents(m: *mapmod.Map) void {
    m.spawn = clampAnchor(m, m.spawn);
    m.portal = clampAnchor(m, m.portal);
    m.bossPos = clampAnchor(m, m.bossPos);
    const flimW = m.halfW - CONTENT_INSET;
    const flimD = m.halfD - CONTENT_INSET;
    var i: usize = m.ledge_count;
    while (i > 0) {
        i -= 1;
        const l = &m.ledges[i];
        l.minX = clampF(l.minX, -flimW, flimW);
        l.maxX = clampF(l.maxX, -flimW, flimW);
        l.minZ = clampF(l.minZ, -flimD, flimD);
        l.maxZ = clampF(l.maxZ, -flimD, flimD);
        if (l.maxX - l.minX < FEATURE_MIN_SPAN or l.maxZ - l.minZ < FEATURE_MIN_SPAN) {
            m.removeLedge(i);
        }
    }
    i = m.ramp_count;
    while (i > 0) {
        i -= 1;
        const r = &m.ramps[i];
        r.minX = clampF(r.minX, -flimW, flimW);
        r.maxX = clampF(r.maxX, -flimW, flimW);
        r.minZ = clampF(r.minZ, -flimD, flimD);
        r.maxZ = clampF(r.maxZ, -flimD, flimD);
        if (r.maxX - r.minX < FEATURE_MIN_SPAN or r.maxZ - r.minZ < FEATURE_MIN_SPAN) {
            m.removeRamp(i);
        }
    }
    // Placed content rides in with the terrain: props/decor/packs pulled inside the
    // shrunken wall too (pasteAt's CONTENT_INSET limits), or they strand outside —
    // void-spawned monsters, floating scenery. No min-span collapse, so just clamp.
    for (m.obstacles[0..m.obstacle_count]) |*o| {
        o.Pos = clampContent(m, o.Pos);
    }
    for (m.decor[0..m.decor_count]) |*d| {
        d.Pos = clampContent(m, d.Pos);
    }
    for (m.packs[0..m.pack_count]) |*p| {
        p.x = clampF(p.x, -flimW, flimW);
        p.z = clampF(p.z, -flimD, flimD);
    }
}

// Move the editor camera focus, clamped to the arena and re-seated on the ground. One
// source for WASD pan, right-drag, and minimap travel so their clamp/ground rules match.
fn setCamTarget(g: *Game, x: f32, z: f32) void {
    g.ed.camTarget.x = clampF(x, -g.map.halfW, g.map.halfW);
    g.ed.camTarget.z = clampF(z, -g.map.halfD, g.map.halfD);
    g.ed.camTarget.y = g.w.groundY(g.ed.camTarget.x, g.ed.camTarget.z);
}

// Move a map anchor (spawn/portal/boss) to a pre-clamped point, banking undo only if it
// actually moves. One guard for the three context-menu rows so they can't drift.
fn setAnchorIfMoved(g: *Game, anchor: *rl.Vector3, ap: rl.Vector3) void {
    if (anchor.x != ap.x or anchor.z != ap.z) {
        bankUndo(g);
        anchor.* = v3(ap.x, 0, ap.z);
        markDirty(g);
    }
}

// Minimap (bottom-right, click-drag recenters): terrain footprint, props, packs,
// the three markers, and the camera's view square.
fn drawMinimap(g: *Game, ctx: *ui.Ctx, W: i32, H: i32) void {
    const ed = &g.ed;
    const mx = W - MM_S - 14;
    const my = H - 30 - MM_S - 14;
    const frame = ui.rect(mx - 5, my - 5, MM_S + 10, MM_S + 10);
    ui.panel(frame, null);
    ui.tipFor(ctx, frame, "The whole map - click or drag to travel");

    // Aspect-fit: a rectangular arena letterboxes inside the square minimap.
    const halfW = g.map.halfW;
    const halfD = g.map.halfD;
    const mmf = @as(f32, @floatFromInt(MM_S));
    const scale = mmf / @max(halfW * 2, halfD * 2);
    const ox = @as(f32, @floatFromInt(mx)) + (mmf - halfW * 2 * scale) / 2;
    const oy = @as(f32, @floatFromInt(my)) + (mmf - halfD * 2 * scale) / 2;

    rl.drawRectangle(@intFromFloat(ox), @intFromFloat(oy), @intFromFloat(halfW * 2 * scale), @intFromFloat(halfD * 2 * scale), lerpColor(g.map.ground, rl.Color.black, 0.45));
    for (g.map.ledges[0..g.map.ledge_count]) |l| {
        rl.drawRectangle(
            @intFromFloat(ox + (l.minX + halfW) * scale),
            @intFromFloat(oy + (l.minZ + halfD) * scale),
            @intFromFloat(@max((l.maxX - l.minX) * scale, 1)),
            @intFromFloat(@max((l.maxZ - l.minZ) * scale, 1)),
            lerpColor(g.map.ground, rl.Color.white, 0.25),
        );
    }
    for (g.map.ramps[0..g.map.ramp_count]) |r| {
        rl.drawRectangle(
            @intFromFloat(ox + (r.minX + halfW) * scale),
            @intFromFloat(oy + (r.minZ + halfD) * scale),
            @intFromFloat(@max((r.maxX - r.minX) * scale, 1)),
            @intFromFloat(@max((r.maxZ - r.minZ) * scale, 1)),
            rgba(120, 150, 110, 255),
        );
    }
    for (g.map.obstacles[0..g.map.obstacle_count]) |o| {
        const col = switch (o.Kind) {
            .rock => rgba(165, 165, 172, 255),
            .tree => rgba(74, 120, 62, 255),
            .gravestone => rgba(195, 195, 205, 255),
        };
        rl.drawRectangle(@intFromFloat(ox + (o.Pos.x + halfW) * scale - 1), @intFromFloat(oy + (o.Pos.z + halfD) * scale - 1), 2, 2, col);
    }
    for (g.map.packList()) |pk| {
        rl.drawRectangle(@intFromFloat(ox + (pk.x + halfW) * scale - 1), @intFromFloat(oy + (pk.z + halfD) * scale - 1), 3, 3, packColor(pk.kind));
    }
    rl.drawRectangle(@intFromFloat(ox + (g.map.bossPos.x + halfW) * scale - 2), @intFromFloat(oy + (g.map.bossPos.z + halfD) * scale - 2), 4, 4, BOSS_COL);
    rl.drawRectangle(@intFromFloat(ox + (g.map.spawn.x + halfW) * scale - 2), @intFromFloat(oy + (g.map.spawn.z + halfD) * scale - 2), 4, 4, SPAWN_COL);
    rl.drawRectangle(@intFromFloat(ox + (g.map.portal.x + halfW) * scale - 2), @intFromFloat(oy + (g.map.portal.z + halfD) * scale - 2), 4, 4, PORTAL_COL);

    // Approximate view square, and click/drag-to-travel.
    const viewHalf = 24.0 / g.rig.zoom;
    const vx: i32 = @intFromFloat(ox + (ed.camTarget.x - viewHalf + halfW) * scale);
    const vy: i32 = @intFromFloat(oy + (ed.camTarget.z - viewHalf + halfD) * scale);
    const vs: i32 = @intFromFloat(2 * viewHalf * scale);
    rl.drawRectangleLines(@max(vx, mx), @max(vy, my), @min(vs, MM_S), @min(vs, MM_S), withAlpha(theme.highlightColor, 220));

    if (rl.checkCollisionPointRec(ctx.mouse, frame)) {
        ctx.anyHot = true;
        if (ctx.down) {
            setCamTarget(g, (ctx.mouse.x - ox) / scale - halfW, (ctx.mouse.y - oy) / scale - halfD);
        }
    }
}

fn drawStatusBar(g: *Game, ctx: *ui.Ctx, W: i32, H: i32) void {
    const ed = &g.ed;
    ui.claimedPanel(ctx, ui.rect(0, H - 30, W, 30), null); // whole bar is chrome
    const hints: [:0]const u8 = "Tab layer   1-9 brush   LMB paint   Shift+drag select   Ctrl+C/X/V   Del   RMB menu/pan   M mirror   [ ] size   Ctrl+Z undo   Ctrl+S save   F5 playtest";
    hudx.text(hints, 12, H - 25, 15, withAlpha(theme.labelColor, 220));

    var right: [ui.MSG_CAP]u8 = undefined;
    var coord: [:0]const u8 = "";
    if (!ed.uiHot) {
        if (mousePoint(g)) |p| {
            coord = std.fmt.bufPrintZ(&right, "{s}{d:.0}, {d:.0}   zoom {d:.1}", .{ if (ed.mirrorX) @as([]const u8, "MIRROR   ") else "", p.x, p.z, g.rig.zoom }) catch "";
        }
    }
    if (coord.len > 0) {
        hudx.text(coord, W - hudx.textW(coord, 15) - 12, H - 25, 15, withAlpha(theme.labelColor, 220));
    }

    if (ed.status_t > 0 and ed.status_len > 0) {
        const s = ed.status_buf[0..ed.status_len :0];
        const w = hudx.textW(s, 19);
        hudx.pill(@divTrunc(W, 2) - @divTrunc(w, 2) - 14, TOPBAR_H + 8, w + 28, 30, withAlpha(theme.ink, 185));
        hudx.text(s, @divTrunc(W, 2) - @divTrunc(w, 2), TOPBAR_H + 14, 19, rgba(255, 245, 210, 255));
    }
}

// ---- Context menu (right-CLICK) ----

fn drawContextMenu(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    if (!ed.ctxOpen or ed.modal != .none) return;
    const p = ed.ctxWorld;
    const m = &g.map;

    // What's under the click? Cross-layer on purpose: the menu acts on exactly this
    // thing, whatever layer it lives on.
    var nearKind: enum { none, ob, dec, pack } = .none;
    var nearIdx: usize = 0;
    var bestD: f32 = 2.0;
    for (m.obstacles[0..m.obstacle_count], 0..) |o, i| {
        if (distXZ(o.Pos, p) < bestD) {
            bestD = distXZ(o.Pos, p);
            nearKind = .ob;
            nearIdx = i;
        }
    }
    for (m.decor[0..m.decor_count], 0..) |d, i| {
        if (distXZ(d.Pos, p) < bestD) {
            bestD = distXZ(d.Pos, p);
            nearKind = .dec;
            nearIdx = i;
        }
    }
    for (m.packs[0..m.pack_count], 0..) |pk, i| {
        if (distXZ(pk.pos(), p) < bestD) {
            bestD = distXZ(pk.pos(), p);
            nearKind = .pack;
            nearIdx = i;
        }
    }

    // A terrain feature under the click gets a re-height row (to current featureH).
    var featKind: enum { none, ledge, ramp } = .none;
    var featIdx: usize = 0;
    for (m.ramps[0..m.ramp_count], 0..) |r0, i| {
        if (r0.contains(p.x, p.z)) {
            featKind = .ramp;
            featIdx = i;
        }
    }
    if (featKind == .none) {
        for (m.ledges[0..m.ledge_count], 0..) |l, i| {
            if (l.contains(p.x, p.z)) {
                featKind = .ledge;
                featIdx = i;
            }
        }
    }

    const rowH = 26;
    const menuW = 188;
    var rows: i32 = 4; // spawn/portal/boss/cancel
    rows += switch (nearKind) {
        .pack => 2,
        .ob, .dec => 1,
        .none => 0,
    };
    if (featKind != .none) rows += 1;
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    const mx: i32 = @min(@as(i32, @intFromFloat(ed.ctxAt.x)), sw - menuW - 6);
    const my: i32 = @min(@as(i32, @intFromFloat(ed.ctxAt.y)), sh - rows * rowH - 18);
    ui.panel(ui.rect(mx, my, menuW, rows * rowH + 12), null);
    var y = my + 6;

    var lb: [48]u8 = undefined;
    switch (nearKind) {
        .pack => {
            const lbl = std.fmt.bufPrintZ(&lb, "Edit {s} pack...", .{@tagName(m.packs[nearIdx].kind)}) catch "Edit pack...";
            if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), lbl, 16, false)) {
                packEditBefore = g.map;
                ed.packEditIdx = nearIdx;
                ed.modal = .pack_edit;
                ed.ctxOpen = false;
            }
            y += rowH;
            if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), "Delete pack", 16, false)) {
                bankUndo(g);
                m.removePack(nearIdx);
                markDirty(g);
                ed.ctxOpen = false;
            }
            y += rowH;
        },
        .ob => {
            const lbl = std.fmt.bufPrintZ(&lb, "Delete {s}", .{@tagName(m.obstacles[nearIdx].Kind)}) catch "Delete";
            if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), lbl, 16, false)) {
                bankUndo(g);
                m.removeObstacle(nearIdx);
                markDirty(g);
                ed.ctxOpen = false;
            }
            y += rowH;
        },
        .dec => {
            const lbl = std.fmt.bufPrintZ(&lb, "Delete {s}", .{@tagName(m.decor[nearIdx].Kind)}) catch "Delete";
            if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), lbl, 16, false)) {
                bankUndo(g);
                m.removeDecor(nearIdx);
                markDirty(g);
                ed.ctxOpen = false;
            }
            y += rowH;
        },
        .none => {},
    }
    if (featKind != .none) {
        var fb: [40]u8 = undefined;
        const flbl = std.fmt.bufPrintZ(&fb, "{s} height -> {d:.1}", .{ if (featKind == .ledge) @as([]const u8, "Ledge") else "Ramp", ed.featureH }) catch "Set height";
        if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), flbl, 16, false)) {
            const cur = switch (featKind) {
                .ledge => m.ledges[featIdx].h,
                .ramp => m.ramps[featIdx].h,
                .none => ed.featureH,
            };
            if (cur != ed.featureH) {
                bankUndo(g);
                switch (featKind) {
                    .ledge => m.ledges[featIdx].h = ed.featureH,
                    .ramp => m.ramps[featIdx].h = ed.featureH,
                    .none => {},
                }
                markDirty(g);
            }
            ed.ctxOpen = false;
        }
        y += rowH;
    }
    // Clamp to the arena inset like the LMB placement path (#L1409); a raw ctxWorld
    // point can land in the void past the wall → unreachable hero/exit + save != authored.
    const ap = clampAnchor(m, p);
    if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), "Move spawn here", 16, false)) {
        setAnchorIfMoved(g, &m.spawn, ap);
        ed.ctxOpen = false;
    }
    y += rowH;
    if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), "Move portal here", 16, false)) {
        setAnchorIfMoved(g, &m.portal, ap);
        ed.ctxOpen = false;
    }
    y += rowH;
    if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), "Move boss here", 16, false)) {
        setAnchorIfMoved(g, &m.bossPos, ap);
        ed.ctxOpen = false;
    }
    y += rowH;
    if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), "Cancel", 16, false)) ed.ctxOpen = false;

    // A click off the menu dismisses it.
    if (ed.ctxOpen and ctx.pressed and !rl.checkCollisionPointRec(ctx.mouse, ui.rect(mx, my, menuW, rows * rowH + 12))) {
        ed.ctxOpen = false;
    }
    if (ed.ctxOpen) ctx.anyHot = true; // the menu owns the pointer while open
}

// ---- Modals ----

fn drawModal(g: *Game, ctx: *ui.Ctx) void {
    const ed = &g.ed;
    switch (ed.modal) {
        .none => {},
        .save_as => {
            const mb = ui.beginModal(ctx, 420, 188, "Save As");
            hudx.text("file name", mb.x + 24, mb.y + 46, 16, withAlpha(theme.labelColor, 230));
            ui.textField(ctx, ui.rect(mb.x + 24, mb.y + 68, 372, 30), &ed.field_buf, &ed.field_len, true, g.elapsed);
            // Live path preview: exactly what doSaveAs will write, so sanitizing
            // never surprises.
            var slug: [40]u8 = undefined;
            var pv: [ui.MSG_CAP]u8 = undefined;
            const s = slugTo(&slug, ed.field_buf[0..ed.field_len]);
            const preview = if (s.len > 0)
                (std.fmt.bufPrintZ(&pv, "Will save to: {s}/{s}{s}", .{ mapmod.dir, s, mapmod.ext }) catch "")
            else
                (std.fmt.bufPrintZ(&pv, "Will save to: -", .{}) catch "");
            hudx.text(preview, mb.x + 24, mb.y + 106, 15, rgba(180, 170, 152, 220));
            if (ui.button(ctx, ui.rect(mb.x + 214, mb.y + 136, 88, 30), "Save", 17, false) or rl.isKeyPressed(.enter)) doSaveAs(g);
            // Cancelling Save-As abandons any guarded action that opened it (e.g. the
            // exit/open confirm via saveCurrent's no-path branch); a leftover `pending`
            // would fire on the NEXT successful save.
            if (ui.button(ctx, ui.rect(mb.x + 310, mb.y + 136, 86, 30), "Cancel", 17, false)) {
                ed.pending = .none;
                ed.modal = .none;
            }
        },
        .rename => {
            const mb = ui.beginModal(ctx, 420, 168, "Rename Map");
            hudx.text("shown on the area banner", mb.x + 24, mb.y + 46, 16, withAlpha(theme.labelColor, 230));
            ui.textField(ctx, ui.rect(mb.x + 24, mb.y + 68, 372, 30), &ed.field_buf, &ed.field_len, true, g.elapsed);
            const ok = ui.button(ctx, ui.rect(mb.x + 214, mb.y + 116, 88, 30), "Rename", 17, false) or rl.isKeyPressed(.enter);
            if (ok and ed.field_len > 0) {
                bankUndo(g);
                g.map.name.set(ed.field_buf[0..ed.field_len]);
                markDirty(g);
                ed.modal = .none;
            }
            if (ui.button(ctx, ui.rect(mb.x + 310, mb.y + 116, 86, 30), "Cancel", 17, false)) ed.modal = .none;
        },
        .new_map => {
            const mb = ui.beginModal(ctx, 420, 232, "New Map");
            hudx.text("name", mb.x + 24, mb.y + 46, 16, withAlpha(theme.labelColor, 230));
            ui.textField(ctx, ui.rect(mb.x + 24, mb.y + 66, 372, 30), &ed.field_buf, &ed.field_len, true, g.elapsed);
            _ = ui.stepperF(ctx, mb.x + 24, mb.y + 106, "width", &ed.newHalfW, HALF_STEP, HALF_MIN, HALF_MAX);
            _ = ui.stepperF(ctx, mb.x + 24, mb.y + 138, "depth", &ed.newHalfD, HALF_STEP, HALF_MIN, HALF_MAX);
            if (ui.button(ctx, ui.rect(mb.x + 214, mb.y + 180, 88, 30), "Create", 17, false) or rl.isKeyPressed(.enter)) doNew(g);
            if (ui.button(ctx, ui.rect(mb.x + 310, mb.y + 180, 86, 30), "Cancel", 17, false)) ed.modal = .none;
        },
        .open_map => {
            const listH: i32 = @intCast(@max(1, g.mapCount) * 34 + 108);
            const mb = ui.beginModal(ctx, 440, listH, "Open Map");
            var y: i32 = mb.y + 48;
            if (g.mapCount == 0) {
                hudx.text("no map files found in maps/", mb.x + 24, y, 15, rgba(210, 195, 175, 230));
                y += 34;
            }
            for (0..g.mapCount) |i| {
                var lb: [104]u8 = undefined;
                const lbl = std.fmt.bufPrintZ(&lb, "{s}", .{g.mapPaths[i][0..g.mapPathLens[i]]}) catch "";
                if (ui.button(ctx, ui.rect(mb.x + 24, y, 392, 28), lbl, 14, i == g.areaIndex)) {
                    ed.modal = .none;
                    requestAction(g, .open, i);
                }
                y += 34;
            }
            if (ui.button(ctx, ui.rect(mb.x + 330, y + 8, 86, 30), "Cancel", 17, false)) ed.modal = .none;
        },
        .confirm => {
            const mb = ui.beginModal(ctx, 460, 150, "Unsaved Changes");
            var msg: [ui.MSG_CAP]u8 = undefined;
            const s = std.fmt.bufPrintZ(&msg, "\"{s}\" has unsaved changes.", .{g.map.name.slice()}) catch "";
            hudx.text(s, mb.x + 24, mb.y + 52, 17, rgba(225, 210, 190, 240));
            const bx = mb.x;
            const by = mb.y + 98;
            if (ui.button(ctx, ui.rect(bx + 24, by, 110, 30), "Save", 17, false)) {
                ed.modal = .none;
                saveCurrent(g); // resumes the pending action on success
            }
            if (ui.button(ctx, ui.rect(bx + 176, by, 110, 30), "Discard", 17, false)) {
                ed.modal = .none;
                ed.dirty = false;
                resumePending(g);
            }
            if (ui.button(ctx, ui.rect(bx + 328, by, 110, 30), "Cancel", 17, false)) {
                ed.modal = .none;
                ed.pending = .none;
            }
        },
        .pack_edit => {
            const mb = ui.beginModal(ctx, 400, 226, "Pack");
            if (ed.packEditIdx >= g.map.pack_count) {
                ed.modal = .none;
                return;
            }
            const pk = &g.map.packs[ed.packEditIdx];
            const bx = mb.x;
            const by = mb.y;
            hudx.text("kind", bx + 24, by + 48, 16, withAlpha(theme.labelColor, 230));
            var cx = bx + 24;
            var used: i32 = 0;
            inline for (@typeInfo(monster.MonsterKind).@"enum".fields) |f| {
                const k: monster.MonsterKind = @enumFromInt(f.value);
                if (ui.chip(ctx, cx, by + 68, f.name, pk.kind == k, &used)) pk.kind = k;
                cx += used;
            }
            var cnt = pk.count;
            if (ui.stepperI(ctx, bx + 24, by + 104, "members", &cnt, PACK_MIN, PACK_MAX)) pk.count = cnt;
            if (ui.button(ctx, ui.rect(bx + 24, by + 172, 100, 30), "Delete", 17, false)) {
                g.map = packEditBefore; // undo any live chip edits first
                pushUndoFrom(&g.map);
                g.map.removePack(ed.packEditIdx);
                markDirty(g);
                ed.modal = .none;
            }
            const done = ui.button(ctx, ui.rect(bx + 286, by + 172, 90, 30), "Done", 17, false) or rl.isKeyPressed(.enter);
            if (done and ed.modal == .pack_edit) {
                if (!std.meta.eql(g.map.packs[ed.packEditIdx], packEditBefore.packs[ed.packEditIdx])) {
                    const now = g.map;
                    g.map = packEditBefore;
                    pushUndoFrom(&g.map);
                    g.map = now;
                    ed.dirty = true;
                }
                ed.modal = .none;
            }
        },
    }
}
