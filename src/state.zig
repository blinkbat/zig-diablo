const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");
const player = @import("player.zig");
const monster = @import("monster.zig");
const projectile = @import("projectile.zig");
const loot = @import("loot.zig");
const camera = @import("camera.zig");

const Monster = monster.Monster;
const Projectile = projectile.Projectile;
const LootDrop = loot.LootDrop;
const Player = player.Player;
const World = world.World;
const CamRig = camera.CamRig;

// The churn lists (monsters/projectiles/loot/popups) grow and clear every area;
// libc is already linked for raylib, so c_allocator is the simplest fit.
const alloc = std.heap.c_allocator;

// HUD effect durations (seconds).
pub const damageFlashDur = 0.4;
pub const toastDur = 2.5;

pub const Scene = enum { menu, playing, dead, victory };

// Popup is floating combat text anchored in the world. Its text lives inline in
// a fixed buffer so the popup is self-contained inside the ArrayList (no GC).
pub const Popup = struct {
    Pos: rl.Vector3 = mathx.zero3,
    text_buf: [32]u8 = undefined,
    text_len: usize = 0,
    Color: rl.Color = mathx.rgba(255, 255, 255, 255),
    Life: f32 = 0,
    maxLife: f32 = 0,

    pub fn text(self: *const Popup) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

// GameState is the entire mutable world.
pub const GameState = struct {
    scene: Scene = .menu,
    rng: mathx.Rng,

    player: Player = .{},
    monsters: std.ArrayList(Monster),
    projectiles: std.ArrayList(Projectile),
    loot: std.ArrayList(LootDrop),
    popups: std.ArrayList(Popup),
    world: World = .{},

    areaIndex: i32 = 0,
    rig: CamRig,
    nextID: i32 = 0,

    // Point-light lighting + cast shadows (the demo's shadowmap technique).
    lightShader: rl.Shader = undefined,
    loc_lightPos: i32 = 0,
    loc_lightColor: i32 = 0,
    loc_ambient: i32 = 0,
    loc_viewPos: i32 = 0,
    lightLoaded: bool = false,
    lightingOn: bool = false,

    shadowShader: rl.Shader = undefined,
    shadowMap: rl.RenderTexture2D = undefined,
    lightVP: rl.Matrix = undefined,
    loc_lightVP: i32 = 0,
    loc_shadowMap: i32 = 0,
    loc_res: i32 = 0,
    shadowReady: bool = false,
    shadowsOn: bool = false,

    // Per-frame input cache.
    mouseGround: rl.Vector3 = mathx.zero3,
    hoverMonster: i32 = -1,
    kbMove: rl.Vector3 = mathx.zero3,

    // Presentation timers + transient text.
    damageFlash: f32 = 0,
    shake: f32 = 0,
    // Stored as buffer + length (not a slice) so GameState can be moved/returned
    // by value without leaving a dangling self-pointer. Read via bannerText/toastText.
    banner_buf: [96]u8 = [_]u8{0} ** 96,
    banner_len: usize = 0,
    bannerTime: f32 = 0,
    toast_buf: [96]u8 = [_]u8{0} ** 96,
    toast_len: usize = 0,
    toastTime: f32 = 0,

    paused: bool = false,
    elapsed: f32 = 0,
    kills: i32 = 0,

    pub fn deinit(g: *GameState) void {
        g.monsters.deinit();
        g.projectiles.deinit();
        g.loot.deinit();
        g.popups.deinit();
    }

    // startRun resets a finished/dead game back to area 0 with a fresh hero.
    pub fn startRun(g: *GameState) void {
        g.player = player.newPlayer(mathx.v3(0, 0, 0));
        g.areaIndex = 0;
        g.kills = 0;
        g.elapsed = 0;
        g.enterArea(0);
        g.scene = .playing;
    }

    // enterArea (re)builds the world for the given area index and spawns packs.
    pub fn enterArea(g: *GameState, idx_in: i32) void {
        const last_area: i32 = @intCast(world.areas.len - 1);
        const idx = mathx.clampI(idx_in, 0, last_area);
        g.areaIndex = idx;
        const def = world.areas[@intCast(idx)];
        const isLast = idx == last_area;
        g.world = world.buildWorld(def, &g.rng, isLast);
        g.monsters.clearRetainingCapacity();
        g.projectiles.clearRetainingCapacity();
        g.loot.clearRetainingCapacity();
        g.popups.clearRetainingCapacity();

        g.spawnPacks(def);

        g.player.Pos = world.startPos(g.world);
        g.player.hasMoveTarget = false;
        g.player.targetMonster = -1;
        g.player.HP = g.player.MaxHP;
        g.player.Mana = g.player.MaxMana;
        g.rig.snap(g.player.Pos);

        g.setBanner("{s}", .{def.name});
        g.bannerTime = 3.5;
        g.setToast("", .{});
    }

    // spawnPacks scatters monster groups, plus one boss far from the spawn.
    fn spawnPacks(g: *GameState, def: world.areaDef) void {
        const spawn_pos = world.startPos(g.world);
        var pack: i32 = 0;
        while (pack < def.packs) : (pack += 1) {
            const center = g.randomOpenTile(spawn_pos, 16);
            const packSize = 2 + g.rng.intn(3);
            const kind = def.kinds[@intCast(g.rng.intn(@intCast(def.kinds.len)))];
            var i: i32 = 0;
            while (i < packSize) : (i += 1) {
                const pos = g.randomOpenTileNear(center, 5);
                g.spawn(monster.makeMonster(kind, def.tier, &g.rng, pos));
            }
        }
        const bossPos = g.randomOpenTileNear(g.world.PortalPos, 8);
        g.spawn(monster.makeBoss(def.tier, &g.rng, bossPos));
    }

    // spawn assigns a stable id and appends the monster.
    fn spawn(g: *GameState, m_in: Monster) void {
        var m = m_in;
        m.id = g.nextID;
        g.nextID += 1;
        g.monsters.append(m) catch @panic("oom");
    }

    // monsterByID returns a pointer to the live monster with the given id, or null.
    pub fn monsterByID(g: *GameState, id: i32) ?*Monster {
        if (id < 0) return null;
        for (g.monsters.items) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    // randomOpenTile finds an unblocked point >= minFromSpawn away from spawn.
    fn randomOpenTile(g: *GameState, spawn_pt: rl.Vector3, minFromSpawn: f32) rl.Vector3 {
        const h = g.world.Half - 3;
        var attempt: i32 = 0;
        while (attempt < 60) : (attempt += 1) {
            const x = (g.rng.float() * 2 - 1) * h;
            const z = (g.rng.float() * 2 - 1) * h;
            const p = mathx.ground(x, z);
            if (mathx.distXZ(p, spawn_pt) < minFromSpawn) continue;
            if (!g.world.blocked(p, 1.0)) return p;
        }
        return mathx.ground(0, 0);
    }

    fn randomOpenTileNear(g: *GameState, center: rl.Vector3, spread: f32) rl.Vector3 {
        var attempt: i32 = 0;
        while (attempt < 40) : (attempt += 1) {
            const x = center.x + (g.rng.float() * 2 - 1) * spread;
            const z = center.z + (g.rng.float() * 2 - 1) * spread;
            const p = mathx.ground(x, z);
            if (!g.world.blocked(p, 0.8)) return p;
        }
        return center;
    }

    pub fn setToast(g: *GameState, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrintZ(&g.toast_buf, fmt, args) catch "";
        g.toast_len = s.len;
        g.toast_buf[g.toast_len] = 0; // keep the buffer null-terminated at len
        g.toastTime = toastDur;
    }

    pub fn toastText(g: *const GameState) [:0]const u8 {
        return g.toast_buf[0..g.toast_len :0];
    }

    // setBanner sets only the banner text; callers set bannerTime themselves.
    pub fn setBanner(g: *GameState, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrintZ(&g.banner_buf, fmt, args) catch "";
        g.banner_len = s.len;
        g.banner_buf[g.banner_len] = 0;
    }

    pub fn bannerText(g: *const GameState) [:0]const u8 {
        return g.banner_buf[0..g.banner_len :0];
    }

    pub fn addPopup(g: *GameState, pos: rl.Vector3, txt: []const u8, col: rl.Color) void {
        var pp = Popup{ .Pos = mathx.v3(pos.x, 1.6, pos.z), .Color = col, .Life = 1.0, .maxLife = 1.0 };
        const n = @min(txt.len, pp.text_buf.len);
        @memcpy(pp.text_buf[0..n], txt[0..n]);
        pp.text_len = n;
        g.popups.append(pp) catch @panic("oom");
    }

    // remainingMonsters counts monsters still alive (not fading out).
    pub fn remainingMonsters(g: *GameState) i32 {
        var n: i32 = 0;
        for (g.monsters.items) |*m| {
            if (m.alive()) n += 1;
        }
        return n;
    }

    // shaderActive reports whether the GPU lighting path is on and usable.
    pub fn shaderActive(g: *const GameState) bool {
        return g.lightingOn and g.lightLoaded;
    }

    // shadowsActive reports whether torch shadow mapping is on and usable.
    pub fn shadowsActive(g: *const GameState) bool {
        return g.shaderActive() and g.shadowReady and g.shadowsOn;
    }
};

pub fn newGame() GameState {
    return newGameSeeded(mathx.timeSeed());
}

// newGameSeeded builds a game with a fixed RNG seed (deterministic world) — used
// by the screenshot debug harness so visual changes are compared apples-to-apples.
pub fn newGameSeeded(seed: u64) GameState {
    var g = GameState{
        .rng = mathx.Rng.init(seed),
        .player = player.newPlayer(mathx.v3(0, 0, 0)),
        .world = .{},
        .rig = camera.newCamRig(),
        .monsters = std.ArrayList(Monster).init(alloc),
        .projectiles = std.ArrayList(Projectile).init(alloc),
        .loot = std.ArrayList(LootDrop).init(alloc),
        .popups = std.ArrayList(Popup).init(alloc),
        .hoverMonster = -1,
    };
    g.enterArea(0); // scene stays .menu; the world behind the menu is area 0
    return g;
}
