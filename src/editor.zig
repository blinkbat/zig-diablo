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
const trigedit = @import("trigedit.zig");

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
    ground,
    decor,
    props,
    entities,

    // Layer count: drives Tab-cycle span, Alt-jump bound, and brushSel[] size.
    pub const N = @typeInfo(Layer).@"enum".fields.len;

    fn label(l: Layer) [:0]const u8 {
        return switch (l) {
            .floor => "Floor",
            .ground => "Ground",
            .decor => "Decor",
            .props => "Props",
            .entities => "Entities",
        };
    }
};

// Brush tables (last entry of every layer is its scoped eraser).
const floorBrushes = [_][:0]const u8{ "Ledge", "Ramp", "Region", "Erase" };
// Ground-material paint brushes: one per world.FloorMat (order-pinned to the enum) + an
// eraser that repaints the map's base material. Painted like decor/props (drag to sweep).
const groundBrushes = [_][:0]const u8{ "dirt", "grass", "stone", "cobble", "mud", "bone", "Erase" };
const decorBrushes = [_][:0]const u8{ "pebble", "tuft", "shroom", "bone", "bigshroom", "Erase" };
const propBrushes = [_][:0]const u8{ "rock", "tree", "gravestone", "Erase" };
const entityBrushes = [_][:0]const u8{ "pib pack", "zombie pack", "skeleton pack", "brute pack", "Boss", "Spawn", "Portal", "NPC", "Erase" };

fn brushesFor(l: Layer) []const [:0]const u8 {
    return switch (l) {
        .floor => &floorBrushes,
        .ground => &groundBrushes,
        .decor => &decorBrushes,
        .props => &propBrushes,
        .entities => &entityBrushes,
    };
}

// Hover blurbs (ui.buttonTip) for the layer strip and every brush.
const layerTips = [_][:0]const u8{
    "Terrain shaping: ledges + ramps (Tab cycles layers)",
    "Paint the floor material per tile (drag to sweep)",
    "Ground dressing: paint or scatter, never blocks",
    "Blocking scenery: rocks, trees, gravestones",
    "Foe packs, the boss, player spawn, the portal",
};
const floorTips = [_][:0]const u8{
    "Drag a rectangle; [ ] sets its height",
    "Drag a rectangle; R (or chips) sets the rise",
    "Drag a rectangle to mark a named zone (triggers key off it)",
    "Click a ledge, ramp, or region to remove it",
};
const groundTips = [_][:0]const u8{
    "Paint dirt (drag to sweep; [ ] sets radius)",
    "Paint grass (drag to sweep)",
    "Paint stone (drag to sweep)",
    "Paint cobble (drag to sweep)",
    "Paint mud (drag to sweep)",
    "Paint bone ground (drag to sweep)",
    "Repaint the base material ([ ] sets radius)",
};
const decorTips = [_][:0]const u8{
    "Paint pebbles (drag to sweep)",
    "Paint grass tufts (drag to sweep)",
    "Paint mushrooms (drag to sweep)",
    "Paint old bones (drag to sweep)",
    "Paint oversized graveyard fungus (drag to sweep)",
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
    "Place a townsperson; click one to edit it",
    "Click-erase packs + NPCs ([ ] sets radius)",
};

fn brushTipsFor(l: Layer) []const [:0]const u8 {
    return switch (l) {
        .floor => &floorTips,
        .ground => &groundTips,
        .decor => &decorTips,
        .props => &propTips,
        .entities => &entityTips,
    };
}

comptime {
    std.debug.assert(layerTips.len == Layer.N); // indexed by layer ordinal
    std.debug.assert(floorTips.len == floorBrushes.len);
    std.debug.assert(groundTips.len == groundBrushes.len);
    std.debug.assert(decorTips.len == decorBrushes.len);
    std.debug.assert(propTips.len == propBrushes.len);
    std.debug.assert(entityTips.len == entityBrushes.len);
}

// Brush tables and their decoders (decorKind/propKind/entityBrush) are parallel
// lists: pin lengths so adding a kind can't silently skew the index mapping.
comptime {
    std.debug.assert(floorBrushes.len == @typeInfo(FloorBrush).@"enum".fields.len);
    std.debug.assert(groundBrushes.len == world.FloorMat.count + 1); // 6 materials + eraser
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
    // Ground brushes: the first N labels ARE the FloorMat tag names in order (groundMat
    // decodes by ordinal into the same ids the grid stores).
    for (0..world.FloorMat.count) |i| {
        std.debug.assert(std.mem.eql(u8, groundBrushes[i], @tagName(@as(world.FloorMat, @enumFromInt(i)))));
    }
    // Entity brushes: the tail labels ("Boss"/"Spawn"/"Portal"/"Erase") ARE EntityBrush's
    // non-pack tag names (case aside), and each pack label contains its MonsterKind tag
    // ("zombie pack" ⊃ "zombie"). Pin BOTH orders so reordering either enum without the
    // brush table is a compile error — entityBrush()/packKind() decode by ordinal.
    const nPacksAssert = @typeInfo(monster.MonsterKind).@"enum".fields.len;
    for (0..@typeInfo(EntityBrush).@"enum".fields.len - 1) |i| {
        std.debug.assert(std.ascii.eqlIgnoreCase(entityBrushes[nPacksAssert + i], @tagName(@as(EntityBrush, @enumFromInt(i + 1)))));
    }
    // Index 0 ("pib pack") is flavor for .fallen; pin the packs whose tag is in the label.
    for (1..nPacksAssert) |i| {
        std.debug.assert(std.mem.startsWith(u8, entityBrushes[i], @tagName(@as(monster.MonsterKind, @enumFromInt(i)))));
    }
}

// Floor-layer brush index (positional, matching floorBrushes).
const FloorBrush = enum { ledge, ramp, region, erase };

// Entities-layer brush index.
const EntityBrush = enum {
    pack,
    boss,
    spawn,
    portal,
    npc,
    erase,

    // The anchor this brush places, if any — so placement routes through the Anchor
    // table (posPtr) rather than re-deriving the Map field, which can't then drift.
    fn anchor(b: EntityBrush) ?Anchor {
        return switch (b) {
            .boss => .boss,
            .spawn => .spawn,
            .portal => .portal,
            else => null,
        };
    }
};

// Marker identity colors, shared by 3D anchors and minimap glyphs.
const SPAWN_COL = rgba(140, 200, 255, 255);
const PORTAL_COL = rgba(190, 140, 255, 255);
const BOSS_COL = rgba(255, 80, 80, 255);

// Erase-brush reds: a ring on each victim the brush would take, a wire box on a floor
// feature it would remove, and the sweep circle showing its reach. One family so the
// "about to be deleted" red reads the same everywhere it's drawn.
const ERASE_RING = rgba(255, 60, 40, 255);
const ERASE_FEATURE = rgba(255, 80, 60, 230);
const ERASE_SWEEP = rgba(255, 90, 70, 200);

// Selection gold, same discipline as the erase reds: the live marquee is a touch
// brighter than the committed box + its center puck + the ledge-drag preview.
const SEL_LIVE = rgba(255, 235, 160, 230);
const SEL_BOX = rgba(255, 220, 120, 255);
const REGION_COL = rgba(110, 205, 235, 220); // named-zone wireframe (StarEdit "location" cyan)

// Map-name / filename field capacity: the typed-name buffer and every slug buffer it
// feeds share this, so a longer name can't silently truncate when slugged to a path.
const NAME_CAP = 40;

// Anchor ring radii, shared by the drawn ring AND its hover-pick zone so a resized
// ring never lies about what's clickable. Hover zone = ring + MARKER_HOVER_PAD.
const SPAWN_R = 1.0;
const PORTAL_R = 1.4;
const BOSS_R = 1.2;
const MARKER_HOVER_PAD = 0.2;

// The three fixed map anchors (hero entry, area exit, boss post). One table binds each
// anchor's Map field, color, ring radius, and context-menu label, so the 3D marker,
// minimap glyph, hover tip, and "Move X here" row can't drift on any of them.
const Anchor = enum {
    spawn,
    portal,
    boss,

    const order = [_]Anchor{ .spawn, .portal, .boss };

    fn posPtr(a: Anchor, m: *mapmod.Map) *rl.Vector3 {
        return switch (a) {
            .spawn => &m.spawn,
            .portal => &m.portal,
            .boss => &m.bossPos,
        };
    }
    fn col(a: Anchor) rl.Color {
        return switch (a) {
            .spawn => SPAWN_COL,
            .portal => PORTAL_COL,
            .boss => BOSS_COL,
        };
    }
    fn radius(a: Anchor) f32 {
        return switch (a) {
            .spawn => SPAWN_R,
            .portal => PORTAL_R,
            .boss => BOSS_R,
        };
    }
    fn moveLabel(a: Anchor) [:0]const u8 {
        return switch (a) {
            .spawn => "Move spawn here",
            .portal => "Move portal here",
            .boss => "Move boss here",
        };
    }
};

// Pack ring radius doubles as the grab pickup radius (clickable == visible).
const PACK_GRAB_R = 1.6;
const NPC_PICK_R = 1.0; // click within this of an NPC to edit it (else a click stamps a new one)

// Right-drag pan deadzone (px): a right-click only becomes a pan past this move, so a
// click-in-place opens the context menu instead. The crawler-editor "4 px threshold".
const RIGHT_DRAG_PX = 4;

// Editor sun: high over the camera target, wide enough to light the view. Follows
// camTarget (not arena center), so its radius spans the lit region around the focus
// rather than the whole map — comfortable for any authored extent (HALF_MAX).
const EDITOR_SUN_H = 38.0;
const EDITOR_SUN_R = 110.0;

pub const Modal = enum { none, save_as, new_map, open_map, rename, confirm, pack_edit, npc_edit, region_edit };
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

// Wireframe box over an XZ rect at height `h` (centered so its base sits on y=0). One
// spelling of the AABB→cube-wires math for every marquee/feature/erase-highlight preview.
fn drawRectBox(minX: f32, maxX: f32, minZ: f32, maxZ: f32, h: f32, col: rl.Color) void {
    rl.drawCubeWiresV(v3((minX + maxX) / 2, h / 2, (minZ + maxZ) / 2), v3(maxX - minX, h, maxZ - minZ), col);
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
var npcEditBefore: mapmod.Map = undefined; // snapshot banked when the NPC modal opens
var regionEditBefore: mapmod.Map = undefined; // snapshot banked when the region modal opens
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

// A mutation (undo pop, paste, delete, scatter) landing mid-gesture interleaves undo
// frames out of order and desyncs armed grabs — every such entry point checks this.
fn midGesture(ed: *const Editor) bool {
    return ed.dragStart != null or ed.grabIdx != null or ed.strokeActive or ed.selMove != null or ed.selDrag != null;
}

fn doUndo(g: *Game) void {
    const ed = &g.ed;
    if (midGesture(ed)) return; // never pop mid-gesture
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
    if (midGesture(ed)) return;
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
    npcEditIdx: usize = 0,
    regionEditIdx: usize = 0,
    // Classic Trigedit (the StarEdit-style trigger editor) — a full-screen surface over the
    // editor. trigOpen routes input there; trigSel is the highlighted trigger.
    trigOpen: bool = false,
    trigSel: usize = 0,

    recovT: f32 = 0, // seconds since the last crash-recovery autosave while dirty

    // Where Ctrl+S writes. Empty until the map's been saved; then Ctrl+S opens
    // Save As instead of guessing a filename.
    path_buf: [mapmod.PATH_CAP]u8 = [_]u8{0} ** mapmod.PATH_CAP,
    path_len: usize = 0,

    modal: Modal = .none,
    pending: Pending = .none, // what the confirm modal resumes on Save/Discard
    pendingOpen: usize = 0,
    field_buf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP, // modal text input
    field_len: usize = 0,
    newHalfW: f32 = mapmod.DEFAULT_HALF,
    newHalfD: f32 = mapmod.DEFAULT_HALF,

    status_buf: [ui.MSG_CAP]u8 = [_]u8{0} ** ui.MSG_CAP,
    status_len: usize = 0,
    status_t: f32 = 0,

    pub fn status(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
        // Truncate on overflow, never drop: a clipped "SAVE FAILED: <path>" beats
        // silence exactly when the path is long enough to blow the cap.
        var scratch: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&scratch, fmt, args) catch &scratch;
        const n = @min(s.len, ed.status_buf.len - 1);
        @memcpy(ed.status_buf[0..n], s[0..n]);
        ed.status_buf[n] = 0;
        ed.status_len = n;
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

    fn groundMat(ed: *const Editor) world.FloorMat {
        return @enumFromInt(@min(ed.brush(), lastVariant(world.FloorMat)));
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
        // decodes correctly rather than collapsing to .erase. The comptime block above
        // pins this tail order (labels ARE the tag names, case aside).
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
    std.fs.cwd().deleteFile(REC_PATH ++ mapmod.bak_ext) catch {};
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
    g.torch.uploadFloorMats(&g.map.floorGrid, g.map.halfW, g.map.halfD);
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

// The pack/NPC/region edit modals all mutate g.map live and share this Done teardown: bank
// an undo frame from the pre-modal snapshot ONLY if the edited record actually changed.
fn bankEdit(g: *Game, before: *const mapmod.Map, changed: bool) void {
    if (!changed) return;
    const now = g.map;
    g.map = before.*;
    pushUndoFrom(&g.map);
    g.map = now;
    g.ed.dirty = true;
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
const HALF_MAX = 120; // "epic map" ceiling, just under map.HALF_MAX's load tolerance
const HALF_STEP = 4;
// Members per pack (PACK panel stepper and pack-edit modal).
const PACK_MIN = 1;
const PACK_MAX = 32; // matches map.PACK_MEMBERS_MAX
// Minimum cursor travel between successive brush placements (stroke density).
const PROP_STEP_MIN = 1.9;
const DECOR_STEP_MIN = 0.8;

comptime {
    // The invariant the two files share: the editor authors INSIDE what the loader
    // tolerates, never past it.
    std.debug.assert(HALF_MAX <= mapmod.HALF_MAX);
    std.debug.assert(PACK_MAX <= mapmod.PACK_MEMBERS_MAX);
}

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
        .decor, .ground => p,
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
        .bigshroom => 0.7 + h * 0.6, // oversized on purpose: reads at prop scale
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

fn placeNpc(g: *Game, p_in: rl.Vector3) bool {
    const ed = &g.ed;
    const m = &g.map;
    if (m.npc_count >= mapmod.MAX_NPCS) {
        ed.status("NPC limit reached", .{});
        return false;
    }
    const p = clampContent(m, p_in);
    m.npcs[m.npc_count] = .{ .kind = .villager, .x = p.x, .z = p.z, .facing = 0 };
    var buf: [12]u8 = undefined;
    m.npcs[m.npc_count].name.set(std.fmt.bufPrint(&buf, "NPC {d}", .{m.npc_count + 1}) catch "NPC");
    m.npc_count += 1;
    return true;
}

// Seed the modal text field with an existing name so an edit starts from it, not empty.
fn seedField(ed: *Editor, s: []const u8) void {
    // Reserve the last byte: ui.textField NUL-terminates at buf[field_len].
    const n = @min(s.len, ed.field_buf.len - 1);
    @memcpy(ed.field_buf[0..n], s[0..n]);
    ed.field_len = n;
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
            var j: usize = m.npc_count;
            while (j > 0) {
                j -= 1;
                if (distXZ(m.npcs[j].pos(), p) < r) {
                    m.removeNpc(j);
                    changed = true;
                }
            }
        },
        .floor, .ground => {},
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
    const m = &g.map;
    const before = m.*; // bank only if something is actually placed (else no-op undo/dirty)
    var dropped: usize = 0;
    var placed: usize = 0;
    for (clipProps[0..clipPropN]) |o| {
        if (m.obstacle_count >= world.MAX_OBSTACLES) {
            dropped += 1;
            continue;
        }
        m.obstacles[m.obstacle_count] = o;
        m.obstacles[m.obstacle_count].Pos = clampContent(m, v3(at.x + o.Pos.x, 0, at.z + o.Pos.z));
        m.obstacle_count += 1;
        placed += 1;
    }
    for (clipDecor[0..clipDecorN]) |d| {
        if (m.decor_count >= world.MAX_DECOR) {
            dropped += 1;
            continue;
        }
        m.decor[m.decor_count] = d;
        m.decor[m.decor_count].Pos = clampContent(m, v3(at.x + d.Pos.x, 0, at.z + d.Pos.z));
        m.decor_count += 1;
        placed += 1;
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
        placed += 1;
    }
    if (placed == 0) return ed.status("nothing pasted (dropped {d}: limits)", .{dropped});
    pushUndoFrom(&before);
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
    for (m.regions[0..m.region_count], 0..) |rg, i| {
        if (rg.contains(p.x, p.z)) {
            m.removeRegion(i);
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
        .region => {
            if (m.region_count >= mapmod.MAX_REGIONS) {
                ed.status("region limit reached", .{});
                return false;
            }
            var rg = mapmod.Region{ .minX = minX, .maxX = maxX, .minZ = minZ, .maxZ = maxZ };
            var buf: [12]u8 = undefined;
            rg.name.set(std.fmt.bufPrint(&buf, "Region {d}", .{m.region_count + 1}) catch "Region");
            m.regions[m.region_count] = rg;
            ed.regionEditIdx = m.region_count;
            m.region_count += 1;
            markDirty(g);
            // Open the rename modal so the zone gets a meaningful name right away. The caller
            // banks the creation as one undo step; renaming banks its own.
            seedField(ed, rg.name.slice());
            regionEditBefore = m.*;
            ed.modal = .region_edit;
            return true;
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
            if (distXZ(tp, ed.lastPaint) < PROP_STEP_MIN) return;
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
            if (distXZ(raw, ed.lastPaint) < DECOR_STEP_MIN) return;
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
        .ground => {
            // Paint the floor-material grid within the brush radius; erase repaints the base.
            const mat = if (ed.isEraseBrush()) g.map.floorBase else ed.groundMat();
            if (g.map.floorPaint(raw.x, raw.z, ed.brushR, mat)) {
                ed.strokeChanged = true;
                g.torch.uploadFloorMats(&g.map.floorGrid, g.map.halfW, g.map.halfD);
                ed.dirty = true; // texture-only edit: no mesh rebuild needed
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
        comptime std.debug.assert(@typeInfo(world.DecorKind).@"enum".fields.len == 5);
        const kind: world.DecorKind = if (roll < 0.34) .pebble else if (roll < 0.76) .tuft else if (roll < 0.88) .shroom else if (roll < 0.94) .bigshroom else .bone;
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
    const target = @min(idx, if (g.mapCount == 0) 0 else g.mapCount - 1);
    if (g.mapCount > 0) {
        // Load directly, not via loadMapAt: its defaultMap fallback would silently bind
        // ed.path to the unreadable file and the next Ctrl+S would clobber it.
        const path = g.mapPaths[target][0..g.mapPathLens[target]];
        g.map = mapmod.load(path) catch |e| {
            ed.status("OPEN FAILED: {s} ({s})", .{ path, @errorName(e) });
            return; // keep editing what's loaded; the file on disk stays untouched
        };
    } else {
        g.map = mapmod.defaultMap();
    }
    g.areaIndex = target;
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
    var slug: [NAME_CAP]u8 = undefined;
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
            // Esc = cancel: pack/NPC modals edit live state, so restore the snapshot.
            switch (ed.modal) {
                .pack_edit => g.map = packEditBefore,
                .npc_edit => g.map = npcEditBefore,
                .region_edit => g.map = regionEditBefore,
                else => {},
            }
            ed.modal = .none;
            // Clear pending, or a stale action fires on the NEXT successful save.
            ed.pending = .none;
        }
        return;
    }

    // The Classic Trigedit surface owns all input while open (like a modal).
    if (ed.trigOpen) {
        trigedit.update(g);
        return;
    }

    const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
    const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
    const alt = freePlace();
    // T opens the trigger editor (Ctrl+T left free). Guarded by !ctrl so Ctrl+ combos pass.
    if (rl.isKeyPressed(.t) and !ctrl) {
        ed.trigOpen = true;
        return;
    }

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
    // Mutating hotkeys share doUndo's mid-gesture gate: a scatter/paste/delete landing
    // inside a live stroke or grab would bank undo frames out of order.
    if (rl.isKeyPressed(.x) and !ctrl and ed.layer == .decor and !midGesture(ed)) scatterDecor(g); // Decor-only, matches Scatter button (Ctrl+X is cut)

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
    if (ctrl and rl.isKeyPressed(.x) and !midGesture(ed)) copySelection(g, true);
    if (ctrl and rl.isKeyPressed(.v) and !midGesture(ed)) {
        if (mousePoint(g)) |p| pasteAt(g, p);
    }
    if (rl.isKeyPressed(.delete) and !midGesture(ed)) deleteSelection(g);
    if (ctrl and rl.isKeyPressed(.r) and recoveryExists()) {
        if (mapmod.load(REC_PATH)) |m| {
            resetTransient(g); // no gesture straddles the map swap (mirrors doOpen)
            // The path doesn't change, so this is an ordinary mutation: the pre-recovery
            // map stays one Ctrl+Z away (a stale autosave must never eat fresh work).
            bankUndo(g);
            g.map = m;
            apply(g);
            ed.dirty = true;
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
            ed.selMove = null; // an orphaned move latch would silently block undo/redo
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
            .decor, .props, .ground => true,
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
            .decor, .props, .ground => {
                if (rl.isMouseButtonPressed(.left)) beginStroke(g);
                pumpStroke(g, p);
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
                        const ap = clampAnchor(&g.map, tp); // anchors use the deeper inset
                        // Route through the Anchor table + setAnchorIfMoved like the
                        // ctx-menu "Move X here" path, so a click on the anchor's current
                        // spot banks no undo frame and raises no false dirty flag.
                        if (ed.entityBrush().anchor()) |a| setAnchorIfMoved(g, a.posPtr(&g.map), ap);
                    }
                },
                .npc => {
                    if (rl.isMouseButtonPressed(.left)) {
                        // Click an existing NPC to edit it; otherwise stamp a new one.
                        var hit: ?usize = null;
                        for (g.map.npcs[0..g.map.npc_count], 0..) |npc, i| {
                            if (distXZ(npc.pos(), p) < NPC_PICK_R) {
                                hit = i;
                                break;
                            }
                        }
                        if (hit) |i| {
                            npcEditBefore = g.map;
                            ed.npcEditIdx = i;
                            seedField(ed, g.map.npcs[i].name.slice());
                            ed.modal = .npc_edit;
                        } else {
                            const before = g.map;
                            if (placeNpc(g, tp)) {
                                markDirty(g);
                                pushUndoFrom(&before);
                            }
                        }
                    }
                },
                .erase => {
                    if (rl.isMouseButtonPressed(.left)) beginStroke(g);
                    pumpStroke(g, p);
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

// Arm a paint/erase stroke: one undo snapshot for the whole gesture, stamp spacing
// reset so the first stamp always lands. Paired with pumpStroke/endStroke — paint and
// entity-erase share the ritual so the undo banking can't drift between them.
fn beginStroke(g: *Game) void {
    const ed = &g.ed;
    ed.strokeActive = true;
    ed.strokeChanged = false;
    strokeBefore = g.map;
    ed.lastPaint = v3(1e9, 0, 1e9);
}

fn pumpStroke(g: *Game, p: rl.Vector3) void {
    const ed = &g.ed;
    if (ed.strokeActive and rl.isMouseButtonDown(.left)) paintStep(g, p);
    if (rl.isMouseButtonReleased(.left) and ed.strokeActive) endStroke(ed);
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
    // Townsfolk, drawn with their real bodies so the town reads at author time.
    for (g.map.npcList()) |npc| gamemod.drawNpcBody(g, npc);
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

    for (Anchor.order) |a| marker(g, a.posPtr(m).*, a.col(), a.radius());

    // Packs: silhouettes show the encounter; here just the grab ring in the kind's
    // color over a dark puck.
    for (m.packList()) |pk| {
        const col = packColor(pk.kind);
        const c = g.w.snapY(pk.pos());
        rl.drawCylinderEx(v3(c.x, c.y + 0.01, c.z), v3(c.x, c.y + 0.03, c.z), PACK_GRAB_R + 0.3, PACK_GRAB_R + 0.3, 20, withAlpha(theme.ink, 120));
        gamemod.groundRing(v3(c.x, c.y + 0.06, c.z), PACK_GRAB_R, col);
        gamemod.groundRing(v3(c.x, c.y + 0.06, c.z), PACK_GRAB_R - 0.15, withAlpha(col, 150));
    }

    // NPCs: a pale pick ring on the ground (the body itself is drawn in the scene pass).
    for (m.npcList()) |npc| {
        const c = g.w.snapY(npc.pos());
        gamemod.groundRing(v3(c.x, c.y + 0.06, c.z), NPC_PICK_R, rgba(214, 202, 180, 235));
    }

    // Regions: a low wireframe box so named zones read on the ground at author time.
    for (m.regionList()) |rg| {
        drawRectBox(rg.minX, rg.maxX, rg.minZ, rg.maxZ, 0.4, REGION_COL);
    }

    // Marquee: the live drag rect, then the committed one.
    if (ed.selDrag) |a| {
        if (mousePoint(g)) |cur| {
            const s = normRect(a, cur);
            drawRectBox(s.minX, s.maxX, s.minZ, s.maxZ, 0.8, SEL_LIVE);
        }
    }
    if (ed.sel) |s| {
        drawRectBox(s.minX, s.maxX, s.minZ, s.maxZ, 0.8, SEL_BOX);
        rl.drawCylinderEx(v3(s.cx(), 0.01, s.cz()), v3(s.cx(), 0.02, s.cz()), 0.3, 0.3, 12, mathx.withAlpha(SEL_BOX, 90));
    }

    // Prop collision circles so spacing reads at a glance. Use the world copy, whose
    // Pos.y already carries the baked groundY (kept in sync by apply), so we don't
    // re-scan every ledge/ramp per obstacle each frame.
    for (g.w.obs()) |o| {
        gamemod.groundRing(v3(o.Pos.x, o.Pos.y + 0.04, o.Pos.z), o.Radius, rgba(255, 255, 255, 50));
    }

    // Live drag rect preview for ledge/ramp (corners snapped like the commit).
    if (ed.dragStart) |a| {
        if (mousePoint(g)) |raw| {
            const s = normRect(a, toolPoint(ed, raw));
            const col = if (ed.floorBrush() == .ledge) mathx.withAlpha(SEL_BOX, 220) else rgba(120, 255, 180, 220);
            drawRectBox(s.minX, s.maxX, s.minZ, s.maxZ, ed.featureH, col);
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
            // Highlight the ONE feature the click would remove — same ramp-then-ledge
            // priority and first-match early-out as eraseFeatureAt, so the preview can't
            // flag features (overlapping ones) that a single click leaves behind.
            highlight: {
                for (g.map.ramps[0..g.map.ramp_count]) |r| {
                    if (r.contains(raw.x, raw.z)) {
                        drawRectBox(r.minX, r.maxX, r.minZ, r.maxZ, r.h, ERASE_FEATURE);
                        break :highlight;
                    }
                }
                for (g.map.ledges[0..g.map.ledge_count]) |l| {
                    if (l.contains(raw.x, raw.z)) {
                        drawRectBox(l.minX, l.maxX, l.minZ, l.maxZ, l.h, ERASE_FEATURE);
                        break :highlight;
                    }
                }
            }
        } else {
            // Sweep circle, plus a ring on everything it would take.
            gamemod.groundRing(v3(raw.x, raw.y + 0.06, raw.z), ed.brushR, ERASE_SWEEP);
            const m = &g.map;
            switch (ed.layer) {
                .props => for (m.obstacles[0..m.obstacle_count]) |o| {
                    if (distXZ(o.Pos, raw) < ed.brushR) {
                        gamemod.groundRing(v3(o.Pos.x, g.w.groundY(o.Pos.x, o.Pos.z) + 0.08, o.Pos.z), o.Radius + 0.15, ERASE_RING);
                    }
                },
                .decor => for (m.decor[0..m.decor_count]) |d| {
                    if (distXZ(d.Pos, raw) < ed.brushR) {
                        gamemod.groundRing(v3(d.Pos.x, g.w.groundY(d.Pos.x, d.Pos.z) + 0.08, d.Pos.z), d.Size + 0.2, ERASE_RING);
                    }
                },
                .entities => for (m.packList()) |pk| {
                    if (distXZ(pk.pos(), raw) < ed.brushR) {
                        const c = g.w.snapY(pk.pos());
                        gamemod.groundRing(v3(c.x, c.y + 0.1, c.z), PACK_GRAB_R + 0.2, ERASE_RING);
                    }
                },
                .floor, .ground => {},
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
const STATUSBAR_H = 30; // bottom hint bar; the minimap seats on top of it
const MM_S = 150; // minimap side
const LAYER_ROW_H = 30; // stride of a layer/brush button row
const STEP_ROW_H = 28; // vertical stride of a property/stepper row in the panels

pub fn drawOverlay(g: *Game) void {
    const ed = &g.ed;
    var ctx = ui.Ctx.begin();
    const W = rl.getScreenWidth();
    const H = rl.getScreenHeight();

    // Classic Trigedit takes over the whole overlay while open.
    if (ed.trigOpen) {
        trigedit.draw(g, &ctx);
        ui.drawTip(&ctx);
        ed.uiHot = ctx.anyHot;
        return;
    }

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
        ctx.tipLen = 0; // silenced chrome must not float its tooltips over the modal
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
    for (Anchor.order) |a| {
        if (distXZ(a.posPtr(m).*, p) >= a.radius() + MARKER_HOVER_PAD) continue;
        switch (a) {
            .spawn => ctx.setTip("Spawn - where the hero enters"),
            .portal => ctx.setTip("Portal - the area exit"),
            .boss => {
                const s = std.fmt.bufPrint(&buf, "Boss post: {s}", .{m.boss.slice()}) catch return;
                ctx.setTip(s);
            },
        }
        return;
    }
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
    if (ui.buttonTip(ctx, ui.rect(x, 7, 84, 26), "Triggers", 17, false, "Open the trigger editor (T)")) ed.trigOpen = true;
    x += 90;

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
            // Guard like deleteSelection: clearing an already-empty list must not bank a
            // no-op undo (evicts a real frame at the cap) or raise a spurious dirty flag.
            if (g.map.decor_count > 0) {
                bankUndo(g);
                g.map.decor_count = 0;
                markDirty(g);
            }
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
    // Cap the stepper at the LARGER of the authoring ceiling and the current extent: a
    // hand-authored map loaded above HALF_MAX (loader tolerates up to map.HALF_MAX) must
    // not silently shrink — and delete clamped-out content — on the first "+" press.
    if (ui.stepperF(ctx, px + 10, y, "width", &halfW, HALF_STEP, HALF_MIN, @max(HALF_MAX, g.map.halfW))) {
        bankUndo(g);
        g.map.halfW = halfW;
        clampContents(&g.map);
        markDirty(g);
    }
    y += STEP_ROW_H;
    ui.tipFor(ctx, ui.rect(px + 8, y - 2, PANEL_W - 16, 26), "North-south half-extent; shrinking clamps contents");
    var halfD = g.map.halfD;
    if (ui.stepperF(ctx, px + 10, y, "depth", &halfD, HALF_STEP, HALF_MIN, @max(HALF_MAX, g.map.halfD))) {
        bankUndo(g);
        g.map.halfD = halfD;
        clampContents(&g.map);
        markDirty(g);
    }
    y += STEP_ROW_H;
    // Base material: fills fresh maps + the Ground eraser + the decor/minimap tone. Paint
    // per-tile on the Ground layer; this is just the default underneath.
    hudx.text("base", px + 10, y + 3, 15, withAlpha(theme.labelColor, 230));
    var sx = px + 76;
    inline for (@typeInfo(world.FloorMat).@"enum".fields) |f| {
        const mat: world.FloorMat = @enumFromInt(f.value);
        ui.tipFor(ctx, ui.rect(sx, y, 22, 22), f.name);
        const active = g.map.floorBase == mat;
        if (ui.swatch(ctx, sx, y, 22, 22, world.FloorMat.base(mat), lerpColor(world.FloorMat.base(mat), rl.Color.black, 0.4), active)) {
            if (!active) {
                bankUndo(g);
                g.map.floorBase = mat;
                markDirty(g);
                ed.status("base material: {s}", .{f.name});
            }
        }
        sx += 24;
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
        .decor, .props, .ground => {
            ui.claimedPanel(ctx, ui.rect(px, y, PANEL_W, 62), "BRUSH");
            ui.tipFor(ctx, ui.rect(px + 8, y + 26, PANEL_W - 16, 26), "Brush radius: paint spread + erase sweep ([ ])");
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
    const my = H - STATUSBAR_H - MM_S - 14;
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

    const mmGround = world.FloorMat.base(g.map.floorBase); // minimap ground tone = base material
    rl.drawRectangle(@intFromFloat(ox), @intFromFloat(oy), @intFromFloat(halfW * 2 * scale), @intFromFloat(halfD * 2 * scale), lerpColor(mmGround, rl.Color.black, 0.45));
    for (g.map.ledges[0..g.map.ledge_count]) |l| {
        rl.drawRectangle(
            @intFromFloat(ox + (l.minX + halfW) * scale),
            @intFromFloat(oy + (l.minZ + halfD) * scale),
            @intFromFloat(@max((l.maxX - l.minX) * scale, 1)),
            @intFromFloat(@max((l.maxZ - l.minZ) * scale, 1)),
            lerpColor(mmGround, rl.Color.white, 0.25),
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
    for (Anchor.order) |a| {
        const ap = a.posPtr(&g.map).*;
        rl.drawRectangle(@intFromFloat(ox + (ap.x + halfW) * scale - 2), @intFromFloat(oy + (ap.z + halfD) * scale - 2), 4, 4, a.col());
    }

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
    ui.claimedPanel(ctx, ui.rect(0, H - STATUSBAR_H, W, STATUSBAR_H), null); // whole bar is chrome
    const hints: [:0]const u8 = "Tab layer   1-9 brush   LMB paint   Shift+drag select   Ctrl+C/X/V   Del   RMB menu/pan   M mirror   [ ] size   Ctrl+Z undo   Ctrl+S save   F5 playtest";
    hudx.text(hints, 12, H - STATUSBAR_H + 5, 15, withAlpha(theme.labelColor, 220));

    var right: [ui.MSG_CAP]u8 = undefined;
    var coord: [:0]const u8 = "";
    if (!ed.uiHot) {
        if (mousePoint(g)) |p| {
            coord = std.fmt.bufPrintZ(&right, "{s}{d:.0}, {d:.0}   zoom {d:.1}", .{ if (ed.mirrorX) @as([]const u8, "MIRROR   ") else "", p.x, p.z, g.rig.zoom }) catch "";
        }
    }
    if (coord.len > 0) {
        hudx.text(coord, W - hudx.textW(coord, 15) - 12, H - STATUSBAR_H + 5, 15, withAlpha(theme.labelColor, 220));
    }

    if (ed.status_t > 0 and ed.status_len > 0) {
        const s = ed.status_buf[0..ed.status_len :0];
        const w = hudx.textW(s, 19);
        hudx.pill(@divTrunc(W, 2) - @divTrunc(w, 2) - 14, TOPBAR_H + 8, w + 28, 30, withAlpha(theme.ink, 185));
        hudx.text(s, @divTrunc(W, 2) - @divTrunc(w, 2), TOPBAR_H + 14, 19, theme.toastText);
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
        const d = distXZ(o.Pos, p);
        if (d < bestD) {
            bestD = d;
            nearKind = .ob;
            nearIdx = i;
        }
    }
    for (m.decor[0..m.decor_count], 0..) |dc, i| {
        const d = distXZ(dc.Pos, p);
        if (d < bestD) {
            bestD = d;
            nearKind = .dec;
            nearIdx = i;
        }
    }
    for (m.packs[0..m.pack_count], 0..) |pk, i| {
        const d = distXZ(pk.pos(), p);
        if (d < bestD) {
            bestD = d;
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
            break; // first match wins, matching eraseFeatureAt / hover tip
        }
    }
    if (featKind == .none) {
        for (m.ledges[0..m.ledge_count], 0..) |l, i| {
            if (l.contains(p.x, p.z)) {
                featKind = .ledge;
                featIdx = i;
                break;
            }
        }
    }

    const rowH = 26;
    const menuW = 188;
    var rows: i32 = @as(i32, @intCast(Anchor.order.len)) + 1; // one "Move X here" per anchor + Cancel
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
    // Clamp to the arena inset via clampAnchor (same as the LMB anchor-placement path); a
    // raw ctxWorld point can land in the void past the wall → unreachable hero/exit + save != authored.
    const ap = clampAnchor(m, p);
    for (Anchor.order) |a| {
        if (ui.button(ctx, ui.rect(mx + 6, y, menuW - 12, rowH - 2), a.moveLabel(), 16, false)) {
            setAnchorIfMoved(g, a.posPtr(m), ap);
            ed.ctxOpen = false;
        }
        y += rowH;
    }
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
            var slug: [NAME_CAP]u8 = undefined;
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
                hudx.text("no map files found in " ++ mapmod.dir ++ "/", mb.x + 24, y, 15, rgba(210, 195, 175, 230));
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
                bankEdit(g, &packEditBefore, !std.meta.eql(g.map.packs[ed.packEditIdx], packEditBefore.packs[ed.packEditIdx]));
                ed.modal = .none;
            }
        },
        .npc_edit => {
            const mb = ui.beginModal(ctx, 460, 300, "NPC");
            if (ed.npcEditIdx >= g.map.npc_count) {
                ed.modal = .none;
                return;
            }
            const npc = &g.map.npcs[ed.npcEditIdx];
            const bx = mb.x;
            const by = mb.y;
            hudx.text("name (triggers address this NPC)", bx + 24, by + 44, 16, withAlpha(theme.labelColor, 230));
            ui.textField(ctx, ui.rect(bx + 24, by + 64, 412, 30), &ed.field_buf, &ed.field_len, true, g.elapsed);
            hudx.text("kind", bx + 24, by + 104, 16, withAlpha(theme.labelColor, 230));
            var cx = bx + 24;
            var cyy = by + 124;
            var used: i32 = 0;
            inline for (@typeInfo(mapmod.NpcKind).@"enum".fields) |f| {
                if (cx > bx + 360) {
                    cx = bx + 24;
                    cyy += 30;
                }
                const k: mapmod.NpcKind = @enumFromInt(f.value);
                if (ui.chip(ctx, cx, cyy, f.name, npc.kind == k, &used)) npc.kind = k;
                cx += used;
            }
            var facing = @as(i32, @intFromFloat(npc.facing));
            if (ui.stepperI(ctx, bx + 24, by + 200, "facing", &facing, 0, 359)) npc.facing = @floatFromInt(facing);
            if (ui.button(ctx, ui.rect(bx + 24, by + 250, 100, 30), "Delete", 17, false)) {
                g.map = npcEditBefore; // drop any live chip edits first
                pushUndoFrom(&g.map);
                g.map.removeNpc(ed.npcEditIdx);
                markDirty(g);
                ed.modal = .none;
            }
            const doneN = ui.button(ctx, ui.rect(bx + 336, by + 250, 100, 30), "Done", 17, false) or rl.isKeyPressed(.enter);
            if (doneN and ed.modal == .npc_edit) {
                if (ed.field_len > 0) npc.name.set(ed.field_buf[0..ed.field_len]);
                bankEdit(g, &npcEditBefore, !std.meta.eql(g.map.npcs[ed.npcEditIdx], npcEditBefore.npcs[ed.npcEditIdx]));
                ed.modal = .none;
            }
        },
        .region_edit => {
            const mb = ui.beginModal(ctx, 440, 232, "Region");
            if (ed.regionEditIdx >= g.map.region_count) {
                ed.modal = .none;
                return;
            }
            const rg = &g.map.regions[ed.regionEditIdx];
            const bx = mb.x;
            const by = mb.y;
            hudx.text("name (triggers reference this zone)", bx + 24, by + 44, 16, withAlpha(theme.labelColor, 230));
            ui.textField(ctx, ui.rect(bx + 24, by + 64, 392, 30), &ed.field_buf, &ed.field_len, true, g.elapsed);
            var buf: [72]u8 = undefined;
            const dims = std.fmt.bufPrintZ(&buf, "x [{d:.1} .. {d:.1}]    z [{d:.1} .. {d:.1}]", .{ rg.minX, rg.maxX, rg.minZ, rg.maxZ }) catch "";
            hudx.text(dims, bx + 24, by + 108, 15, rgba(180, 170, 152, 220));
            hudx.text("(drag a new box on the Floor layer to re-place)", bx + 24, by + 132, 14, withAlpha(theme.labelColor, 180));
            if (ui.button(ctx, ui.rect(bx + 24, by + 178, 100, 30), "Delete", 17, false)) {
                g.map = regionEditBefore;
                pushUndoFrom(&g.map);
                g.map.removeRegion(ed.regionEditIdx);
                markDirty(g);
                ed.modal = .none;
            }
            const doneR = ui.button(ctx, ui.rect(bx + 316, by + 178, 100, 30), "Done", 17, false) or rl.isKeyPressed(.enter);
            if (doneR and ed.modal == .region_edit) {
                if (ed.field_len > 0) rg.name.set(ed.field_buf[0..ed.field_len]);
                bankEdit(g, &regionEditBefore, !std.meta.eql(g.map.regions[ed.regionEditIdx], regionEditBefore.regions[ed.regionEditIdx]));
                ed.modal = .none;
            }
        },
    }
}
