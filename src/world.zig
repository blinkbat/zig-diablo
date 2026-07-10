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

// TERRAIN — prototype "ledge" verticality. The world stays a SINGLE-VALUED
// heightfield (one walkable height per XZ point, nothing walkable underneath
// anything), which is exactly the constraint that keeps the overhead shadow rig
// and the planar fog grid working. A Ledge is a raised axis-aligned platform; a
// Ramp is a sloped rectangle joining the floor to a ledge edge.
pub const STEP_MAX = 0.6; // tallest height difference feet can walk over

pub const Ledge = struct {
    minX: f32,
    maxX: f32,
    minZ: f32,
    maxZ: f32,
    h: f32,
};

pub const Ramp = struct {
    minX: f32,
    maxX: f32,
    minZ: f32,
    maxZ: f32,
    h: f32,
    // Which way the slope climbs: height is 0 at the opposite edge and h here.
    rise: enum(u8) { xpos, xneg, zpos, zneg },

    // The ramp's top surface as y = kx*x + kz*z + c (it's a plane).
    pub fn planeCoeffs(r: Ramp) [3]f32 {
        return switch (r.rise) {
            .xpos => .{ r.h / (r.maxX - r.minX), 0, -r.h * r.minX / (r.maxX - r.minX) },
            .xneg => .{ -r.h / (r.maxX - r.minX), 0, r.h * r.maxX / (r.maxX - r.minX) },
            .zpos => .{ 0, r.h / (r.maxZ - r.minZ), -r.h * r.minZ / (r.maxZ - r.minZ) },
            .zneg => .{ 0, -r.h / (r.maxZ - r.minZ), r.h * r.maxZ / (r.maxZ - r.minZ) },
        };
    }
};

pub const MAX_LEDGES = 4;
pub const MAX_RAMPS = 4;

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
    ledges: [MAX_LEDGES]Ledge = undefined,
    ledge_count: usize = 0,
    ramps: [MAX_RAMPS]Ramp = undefined,
    ramp_count: usize = 0,
    PortalPos: rl.Vector3 = mathx.zero3,
    PortalOpen: bool = false,
    IsLast: bool = false,

    pub fn obs(self: *const World) []const Obstacle {
        return self.obstacles[0..self.obstacle_count];
    }

    pub fn dec(self: *const World) []const Decor {
        return self.decor[0..self.decor_count];
    }

    pub fn led(self: *const World) []const Ledge {
        return self.ledges[0..self.ledge_count];
    }

    pub fn rmp(self: *const World) []const Ramp {
        return self.ramps[0..self.ramp_count];
    }

    /// Walkable ground height at an XZ point. Ramps win over ledges (a ramp is cut
    /// against a ledge edge), everything else is the flat floor at 0.
    pub fn groundY(self: *const World, x: f32, z: f32) f32 {
        for (self.rmp()) |r| {
            if (x >= r.minX and x <= r.maxX and z >= r.minZ and z <= r.maxZ) {
                const k = r.planeCoeffs();
                return k[0] * x + k[1] * z + k[2];
            }
        }
        for (self.led()) |l| {
            if (x >= l.minX and x <= l.maxX and z >= l.minZ and z <= l.maxZ) return l.h;
        }
        return 0;
    }

    /// p with its y snapped onto the walkable ground.
    pub fn snapY(self: *const World, p: rl.Vector3) rl.Vector3 {
        return v3(p.x, self.groundY(p.x, p.z), p.z);
    }

    /// Whether an XZ point lies inside any ledge or ramp footprint (used to keep
    /// worldgen scatter off the terrain features).
    pub fn onFeature(self: *const World, x: f32, z: f32) bool {
        for (self.rmp()) |r| {
            if (x >= r.minX and x <= r.maxX and z >= r.minZ and z <= r.maxZ) return true;
        }
        for (self.led()) |l| {
            if (x >= l.minX and x <= l.maxX and z >= l.minZ and z <= l.maxZ) return true;
        }
        return false;
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

    // A step is passable when it's clear of scenery AND the ground doesn't rise or
    // drop more than feet can manage — cliff faces are walls, ramps are gradual.
    fn passable(self: *const World, p: rl.Vector3, radius: f32, fromY: f32) bool {
        if (self.blocked(p, radius)) return false;
        return @abs(self.groundY(p.x, p.z) - fromY) <= STEP_MAX;
    }

    /// Move from pos by delta, sliding along obstacles (full, then X-only, then
    /// Z-only). The returned position carries the correct ground height in y.
    pub fn moveWithCollision(self: *const World, pos: rl.Vector3, delta: rl.Vector3, radius: f32) rl.Vector3 {
        const fromY = self.groundY(pos.x, pos.z);
        const tryPos = v3(pos.x + delta.x, 0, pos.z + delta.z);
        if (self.passable(tryPos, radius, fromY)) return self.snapY(tryPos);
        const xPos = v3(pos.x + delta.x, 0, pos.z);
        if (self.passable(xPos, radius, fromY)) return self.snapY(xPos);
        const zPos = v3(pos.x, 0, pos.z + delta.z);
        if (self.passable(zPos, radius, fromY)) return self.snapY(zPos);
        return self.snapY(pos);
    }

    /// Whether a projectile at p struck scenery tall enough to block it (a shot
    /// flying above an obstacle clears it), the arena edge, or terrain (cliff
    /// faces are cover: a bolt below a ledge top splats against its side).
    pub fn rayHitsObstacle(self: *const World, p: rl.Vector3, radius: f32) bool {
        if (@abs(p.x) > self.Half or @abs(p.z) > self.Half) return true;
        if (self.groundY(p.x, p.z) > p.y) return true;
        for (self.obs()) |o| {
            if (o.Height < 1.0) continue;
            if (p.y > o.Pos.y + o.Height + 0.3) continue;
            const rr = o.Radius + radius;
            if (dist2XZ(o.Pos, p) < rr * rr) return true;
        }
        return false;
    }

    /// Terrain-aware mouse picking: intersect the ray with the floor plane, every
    /// ledge top, and every ramp plane; return the NEAREST hit that actually lies
    /// on that surface (so a click on a rampart lands on the rampart, not on the
    /// floor plane hidden beneath it).
    pub fn pickGround(self: *const World, ray: rl.Ray) ?rl.Vector3 {
        var best: ?rl.Vector3 = null;
        var bestT: f32 = std.math.floatMax(f32);
        if (rayAtPlane(ray, 0, 0, 0)) |hit| {
            if (hit.t < bestT and self.groundY(hit.p.x, hit.p.z) < 0.01) {
                bestT = hit.t;
                best = hit.p;
            }
        }
        for (self.led()) |l| {
            if (rayAtPlane(ray, 0, 0, l.h)) |hit| {
                if (hit.t < bestT and hit.p.x >= l.minX and hit.p.x <= l.maxX and hit.p.z >= l.minZ and hit.p.z <= l.maxZ) {
                    bestT = hit.t;
                    best = hit.p;
                }
            }
        }
        for (self.rmp()) |r| {
            const k = r.planeCoeffs();
            if (rayAtPlane(ray, k[0], k[1], k[2])) |hit| {
                if (hit.t < bestT and hit.p.x >= r.minX and hit.p.x <= r.maxX and hit.p.z >= r.minZ and hit.p.z <= r.maxZ) {
                    bestT = hit.t;
                    best = hit.p;
                }
            }
        }
        return best;
    }
};

// Intersect a ray with the plane y = kx*x + kz*z + c (horizontal when kx=kz=0).
fn rayAtPlane(ray: rl.Ray, kx: f32, kz: f32, c: f32) ?struct { p: rl.Vector3, t: f32 } {
    const denom = ray.direction.y - kx * ray.direction.x - kz * ray.direction.z;
    if (@abs(denom) < 1e-6) return null;
    const t = (kx * ray.position.x + kz * ray.position.z + c - ray.position.y) / denom;
    if (t < 0) return null;
    const x = ray.position.x + ray.direction.x * t;
    const z = ray.position.z + ray.direction.z * t;
    return .{ .p = v3(x, kx * x + kz * z + c, z), .t = t };
}

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

    // TERRAIN TEST (Blood Moor only for now): a rampart walkway along the east
    // wall near the spawn, reached by a ramp on its south-west corner — high
    // ground to rain firebolts from while the floor boils below. Defined BEFORE
    // the scatter passes so obstacles and decor can stay off it.
    if (def.tier == 0) {
        w.ledges[0] = .{ .minX = 26, .maxX = def.half - 1.4, .minZ = 4, .maxZ = 30, .h = 2.4 };
        w.ledge_count = 1;
        w.ramps[0] = .{ .minX = 20.5, .maxX = 26, .minZ = 24, .maxZ = 29.5, .h = 2.4, .rise = .xpos };
        w.ramp_count = 1;
    }

    const spawn = startPos(w);
    const count: i32 = @intFromFloat(def.half * 0.9);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        var attempt: i32 = 0;
        while (attempt < 8) : (attempt += 1) {
            const x = (rng.float() * 2 - 1) * (def.half - 3);
            const z = (rng.float() * 2 - 1) * (def.half - 3);
            const p = ground(x, z);
            // Keep scenery away from spawn and portal so neither gets walled in,
            // and off the terrain features (the rampart top stays a clear firing
            // platform; nothing may straddle a cliff face or the ramp).
            if (distXZ(p, spawn) < 8 or distXZ(p, w.PortalPos) < 8) continue;
            if (w.onFeature(x, z)) continue;
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
        if (w.onFeature(p.x, p.z)) continue;
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
