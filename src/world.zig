const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const monster = @import("monster.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const ground = mathx.ground;
const distXZ = mathx.distXZ;
const dist2XZ = mathx.dist2XZ;
const lerpColor = mathx.lerpColor;
const Rng = mathx.Rng;

// Obstacle is a blocking piece of scenery. Collision is circular in the XZ plane.
pub const ObstacleKind = enum(u8) { rock, tree, gravestone };

pub const Obstacle = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Radius: f32 = 0,
    Height: f32 = 0,
    Kind: ObstacleKind = .rock,
    Tint: rl.Color = rgba(255, 255, 255, 255),
};

// Scenery is bounded (a few dozen per area), so the world owns a fixed array —
// no allocator, no per-area free. Well above the max any area generates.
pub const MAX_OBSTACLES = 160;

// Decor is non-blocking ground dressing (pebbles, grass tufts, mushrooms, old
// bones): no collision, no shadows worth speaking of — just scale cues so the floor
// between obstacles isn't a featureless plane. Baked into the scene mesh with the
// obstacles.
pub const DecorKind = enum(u8) { pebble, tuft, shroom, bone };

pub const Decor = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Size: f32 = 0,
    Kind: DecorKind = .pebble,
    Tint: rl.Color = rgba(255, 255, 255, 255),
};

pub const MAX_DECOR = 512;

// World holds the static level: extents, scenery, and the exit portal.
pub const World = struct {
    Half: f32 = 0, // arena spans -Half..Half on X and Z
    Ground: rl.Color = rgba(255, 255, 255, 255),
    Accent: rl.Color = rgba(255, 255, 255, 255),
    Name: []const u8 = "",
    obstacles: [MAX_OBSTACLES]Obstacle = undefined,
    obstacle_count: usize = 0,
    decor: [MAX_DECOR]Decor = undefined,
    decor_count: usize = 0,
    PortalPos: rl.Vector3 = mathx.zero3,
    PortalOpen: bool = false,
    IsLast: bool = false,

    pub fn obs(self: *const World) []const Obstacle {
        return self.obstacles[0..self.obstacle_count];
    }

    pub fn dec(self: *const World) []const Decor {
        return self.decor[0..self.decor_count];
    }

    /// Whether a circle of the given radius at p hits scenery or leaves the arena.
    pub fn blocked(self: *const World, p: rl.Vector3, radius: f32) bool {
        if (@abs(p.x) > self.Half - radius or @abs(p.z) > self.Half - radius) return true;
        for (self.obs()) |o| {
            const rr = o.Radius + radius;
            if (dist2XZ(o.Pos, p) < rr * rr) return true;
        }
        return false;
    }

    /// Move from pos by delta, sliding along obstacles (full, then X-only, then Z-only).
    pub fn moveWithCollision(self: *const World, pos: rl.Vector3, delta: rl.Vector3, radius: f32) rl.Vector3 {
        const tryPos = v3(pos.x + delta.x, 0, pos.z + delta.z);
        if (!self.blocked(tryPos, radius)) return tryPos;
        const xPos = v3(pos.x + delta.x, 0, pos.z);
        if (!self.blocked(xPos, radius)) return xPos;
        const zPos = v3(pos.x, 0, pos.z + delta.z);
        if (!self.blocked(zPos, radius)) return zPos;
        return pos;
    }

    /// Whether a projectile at p struck scenery tall enough to block it.
    pub fn rayHitsObstacle(self: *const World, p: rl.Vector3, radius: f32) bool {
        if (@abs(p.x) > self.Half or @abs(p.z) > self.Half) return true;
        for (self.obs()) |o| {
            if (o.Height < 1.0) continue;
            const rr = o.Radius + radius;
            if (dist2XZ(o.Pos, p) < rr * rr) return true;
        }
        return false;
    }
};

// areaDef is a template for a level. Difficulty scales with tier.
pub const areaDef = struct {
    name: []const u8,
    ground: rl.Color,
    accent: rl.Color,
    // The torch's light color in this area — each floor gets its own night: amber on
    // the moor, pale over the cold plains, sickly under the dark wood, violet-cold in
    // the catacombs. Uploaded once per area (torchlight.setLightColor).
    light: [3]f32,
    half: f32,
    packs: i32,
    tier: i32,
    kinds: []const monster.MonsterKind,
    boss: []const u8, // the area champion's name (co-located so it can't drift from the area)
};

pub const areas = [_]areaDef{
    .{ .name = "The Blood Moor", .ground = rgba(92, 80, 62, 255), .accent = rgba(72, 62, 50, 255), .light = .{ 1.04, 0.94, 0.80 }, .half = 38, .packs = 4, .tier = 0, .kinds = &.{ .fallen, .fallen, .zombie }, .boss = "Bishibosh" },
    .{ .name = "Cold Plains", .ground = rgba(108, 120, 138, 255), .accent = rgba(86, 96, 112, 255), .light = .{ 0.90, 0.97, 1.08 }, .half = 44, .packs = 5, .tier = 1, .kinds = &.{ .fallen, .zombie, .skeleton }, .boss = "Rakanishu" },
    .{ .name = "The Stony Field", .ground = rgba(96, 92, 80, 255), .accent = rgba(74, 70, 60, 255), .light = .{ 1.00, 0.96, 0.87 }, .half = 46, .packs = 6, .tier = 2, .kinds = &.{ .zombie, .skeleton, .fallen }, .boss = "Treehead Woodfist" },
    .{ .name = "The Dark Wood", .ground = rgba(62, 58, 48, 255), .accent = rgba(48, 46, 38, 255), .light = .{ 0.88, 1.00, 0.88 }, .half = 48, .packs = 7, .tier = 3, .kinds = &.{ .skeleton, .zombie, .brute }, .boss = "Pitspawn Fouldog" },
    .{ .name = "The Catacombs", .ground = rgba(54, 46, 60, 255), .accent = rgba(40, 34, 46, 255), .light = .{ 0.93, 0.87, 1.08 }, .half = 48, .packs = 8, .tier = 4, .kinds = &.{ .skeleton, .brute, .zombie }, .boss = "Coldcrow" },
};

// How far the spawn and the exit portal sit in from their (opposite) arena walls.
// Shared so buildWorld places them exactly where startPos/PortalPos report them.
const SPAWN_INSET = 6;
const PORTAL_INSET = 7;

// startPos is where the player spawns in each area.
pub fn startPos(w: World) rl.Vector3 {
    return ground(0, w.Half - SPAWN_INSET);
}

// buildWorld generates static scenery and places the portal opposite the spawn.
pub fn buildWorld(def: areaDef, rng: *Rng, isLast: bool) World {
    var w = World{
        .Half = def.half,
        .Ground = def.ground,
        .Accent = def.accent,
        .Name = def.name,
        .PortalPos = ground(0, -(def.half - PORTAL_INSET)),
        .IsLast = isLast,
    };

    const spawn = startPos(w);
    const count: i32 = @intFromFloat(def.half * 0.9);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        var attempt: i32 = 0;
        while (attempt < 8) : (attempt += 1) {
            const x = (rng.float() * 2 - 1) * (def.half - 3);
            const z = (rng.float() * 2 - 1) * (def.half - 3);
            const p = ground(x, z);
            // Keep scenery away from spawn and portal so neither gets walled in.
            if (distXZ(p, spawn) < 8 or distXZ(p, w.PortalPos) < 8) continue;
            const ob = randomObstacle(def, rng, p);
            if (obstacleOverlaps(w.obs(), ob)) continue;
            if (w.obstacle_count >= MAX_OBSTACLES) break;
            w.obstacles[w.obstacle_count] = ob;
            w.obstacle_count += 1;
            break;
        }
    }

    // Ground dressing: dense, cheap, and collision-free. Placed after obstacles so
    // it can dodge them (a tuft sunk inside a boulder is wasted verts).
    const dcount: i32 = @intFromFloat(def.half * 4.5);
    var j: i32 = 0;
    while (j < dcount) : (j += 1) {
        if (w.decor_count >= MAX_DECOR) break;
        const p = ground((rng.float() * 2 - 1) * (def.half - 2), (rng.float() * 2 - 1) * (def.half - 2));
        if (w.blocked(p, 0.3)) continue;
        const roll = rng.float();
        w.decor[w.decor_count] = if (roll < 0.36) Decor{
            .Pos = p,
            .Size = 0.1 + rng.float() * 0.2,
            .Kind = .pebble,
            .Tint = lerpColor(def.accent, rgba(140, 138, 132, 255), 0.3 + rng.float() * 0.4),
        } else if (roll < 0.8) Decor{
            .Pos = p,
            .Size = 0.3 + rng.float() * 0.35,
            .Kind = .tuft,
            .Tint = lerpColor(def.ground, rgba(105, 140, 70, 255), 0.4 + rng.float() * 0.3),
        } else if (roll < 0.92) Decor{
            .Pos = p,
            .Size = 0.16 + rng.float() * 0.14,
            .Kind = .shroom,
            .Tint = if (rng.float() < 0.5) rgba(214, 168, 96, 255) else rgba(190, 120, 130, 255),
        } else Decor{
            // Old bones: this world eats people. A rare ivory scatter sells it.
            .Pos = p,
            .Size = 0.25 + rng.float() * 0.25,
            .Kind = .bone,
            .Tint = lerpColor(rgba(212, 205, 185, 255), def.ground, 0.15 + rng.float() * 0.15),
        };
        w.decor_count += 1;
    }
    return w;
}

fn randomObstacle(def: areaDef, rng: *Rng, p: rl.Vector3) Obstacle {
    // Pick a kind from the enum's own value list (not a bare int) so reordering
    // ObstacleKind can't silently remap what spawns.
    const kinds = comptime std.enums.values(ObstacleKind);
    const kind = kinds[@intCast(rng.intn(kinds.len))];
    return switch (kind) {
        .tree => Obstacle{ .Pos = p, .Radius = 0.9 + rng.float() * 0.5, .Height = 4 + rng.float() * 3, .Kind = .tree, .Tint = lerpColor(def.accent, rgba(40, 70, 36, 255), 0.6) },
        // Weathered slate, pulled a little toward the area accent so the yard's stones
        // belong to their ground (and vary head to head instead of one flat grey).
        .gravestone => Obstacle{ .Pos = p, .Radius = 0.7, .Height = 1.6 + rng.float(), .Kind = .gravestone, .Tint = lerpColor(rgba(86, 88, 98, 255), def.accent, 0.2 + rng.float() * 0.2) },
        .rock => Obstacle{ .Pos = p, .Radius = 1.0 + rng.float() * 0.8, .Height = 1.2 + rng.float() * 1.5, .Kind = .rock, .Tint = lerpColor(def.accent, rgba(90, 90, 96, 255), 0.5) },
    };
}

fn obstacleOverlaps(existing: []const Obstacle, c: Obstacle) bool {
    for (existing) |o| {
        if (distXZ(o.Pos, c.Pos) < o.Radius + c.Radius + 0.5) return true;
    }
    return false;
}
