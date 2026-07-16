const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const dist2XZ = mathx.dist2XZ;

// FLOOR MATERIALS — the ground is real terrain, not a tinted plane. Each area names
// three materials (primary, secondary patches, rare tertiary) and the scene shader
// paints/blends them procedurally by world position (torchlight.zig matAlbedo — the
// looks live THERE; base() below only mirrors each material's base tone for derived
// tints and the editor minimap, so keep the two in sync).
pub const FloorMat = enum(u8) {
    dirt,
    grass,
    stone,
    cobble,
    mud,
    bone,

    pub fn base(m: FloorMat) rl.Color {
        return switch (m) {
            .dirt => rl.Color.init(60, 50, 37, 255),
            .grass => rl.Color.init(41, 51, 28, 255),
            .stone => rl.Color.init(61, 60, 56, 255),
            .cobble => rl.Color.init(59, 56, 51, 255),
            .mud => rl.Color.init(31, 25, 18, 255),
            .bone => rl.Color.init(46, 42, 36, 255),
        };
    }
};

// primary / secondary / tertiary — repeat a name to narrow an area's variety.
pub const FloorSet = [3]FloorMat;

// Masonry tone for arena walls, ledge bodies, and ramp skirts — one stone for every
// built structure now that the per-map accent palette is gone.
pub const MASONRY = rl.Color.init(56, 54, 48, 255);

// Blocking scenery; collision is circular in the XZ plane.
pub const ObstacleKind = enum(u8) { rock, tree, gravestone };

pub const Obstacle = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Radius: f32 = 0,
    Height: f32 = 0,
    Kind: ObstacleKind = .rock,
    Tint: rl.Color = rl.Color.white,
};

// Bounded scenery, so a fixed array (no allocator). Above any area's max — sized
// for "epic" maps at the raised HALF_MAX playfield.
pub const MAX_OBSTACLES = 512;

// Decor is non-blocking ground dressing (pebbles/tufts/shrooms/bones/big fungus):
// scale cues only, no collision. Baked into the scene mesh with the obstacles.
pub const DecorKind = enum(u8) { pebble, tuft, shroom, bone, bigshroom };

pub const Decor = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Size: f32 = 0,
    Kind: DecorKind = .pebble,
    Tint: rl.Color = rl.Color.white,
};

pub const MAX_DECOR = 2048;

// TERRAIN — "ledge" verticality. World stays a SINGLE-VALUED heightfield (one
// walkable height per XZ, nothing walkable underneath) — the constraint that keeps
// the overhead shadow rig and planar fog grid valid. Ledge = raised AABB platform;
// Ramp = sloped rect joining floor to a ledge edge.
pub const STEP_MAX = 0.6; // tallest height difference feet can walk over

// Point-in-AABB in XZ — shared footprint test for groundY, onFeature, picking,
// and the editor's erase/hover/context.
pub fn inRect(minX: f32, maxX: f32, minZ: f32, maxZ: f32, x: f32, z: f32) bool {
    return x >= minX and x <= maxX and z >= minZ and z <= maxZ;
}

pub const Ledge = struct {
    minX: f32,
    maxX: f32,
    minZ: f32,
    maxZ: f32,
    h: f32,

    pub fn contains(l: Ledge, x: f32, z: f32) bool {
        return inRect(l.minX, l.maxX, l.minZ, l.maxZ, x, z);
    }
};

// Which way a ramp climbs: h at this edge, 0 at the opposite. Named (not anonymous)
// so the map format round-trips it by tag.
pub const RampRise = enum(u8) { xpos, xneg, zpos, zneg };

pub const Ramp = struct {
    minX: f32,
    maxX: f32,
    minZ: f32,
    maxZ: f32,
    h: f32,
    rise: RampRise,

    pub fn contains(r: Ramp, x: f32, z: f32) bool {
        return inRect(r.minX, r.maxX, r.minZ, r.maxZ, x, z);
    }

    // Ramp top surface as the plane y = kx*x + kz*z + c. A zero-extent rect on the
    // rise axis would divide by zero (inf/NaN through groundY/picking), so a
    // collapsed ramp falls back to a flat shelf at h.
    pub fn planeCoeffs(r: Ramp) [3]f32 {
        const dx = r.maxX - r.minX;
        const dz = r.maxZ - r.minZ;
        return switch (r.rise) {
            .xpos => if (dx > 1e-4) .{ r.h / dx, 0, -r.h * r.minX / dx } else .{ 0, 0, r.h },
            .xneg => if (dx > 1e-4) .{ -r.h / dx, 0, r.h * r.maxX / dx } else .{ 0, 0, r.h },
            .zpos => if (dz > 1e-4) .{ 0, r.h / dz, -r.h * r.minZ / dz } else .{ 0, 0, r.h },
            .zneg => if (dz > 1e-4) .{ 0, -r.h / dz, r.h * r.maxZ / dz } else .{ 0, 0, r.h },
        };
    }

    // Height of the ramp's top surface at (x,z) — the plane eval `k·(x,z)+c`. The one
    // source for the slope so groundY and the mesh bake can't drift from each other.
    pub fn heightAt(r: Ramp, x: f32, z: f32) f32 {
        const k = r.planeCoeffs();
        return k[0] * x + k[1] * z + k[2];
    }
};

pub const MAX_LEDGES = 16;
pub const MAX_RAMPS = 16;

// Static level: extents, scenery, and the exit portal.
pub const World = struct {
    HalfW: f32 = 0, // arena spans -HalfW..HalfW on X
    HalfD: f32 = 0, // ...and -HalfD..HalfD on Z (rectangular arenas welcome)
    Floor: FloorSet = .{ .dirt, .grass, .stone },
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

    /// Walkable ground height at XZ. Ramps win over ledges (a ramp is cut against a
    /// ledge edge); everything else is the flat floor at 0.
    pub fn groundY(self: *const World, x: f32, z: f32) f32 {
        for (self.rmp()) |r| {
            if (r.contains(x, z)) return r.heightAt(x, z);
        }
        for (self.led()) |l| {
            if (l.contains(x, z)) return l.h;
        }
        return 0;
    }

    /// p with its y snapped onto the walkable ground.
    pub fn snapY(self: *const World, p: rl.Vector3) rl.Vector3 {
        return v3(p.x, self.groundY(p.x, p.z), p.z);
    }

    /// Whether XZ lies inside any ledge/ramp footprint (keeps scatter off features).
    pub fn onFeature(self: *const World, x: f32, z: f32) bool {
        for (self.rmp()) |r| {
            if (r.contains(x, z)) return true;
        }
        for (self.led()) |l| {
            if (l.contains(x, z)) return true;
        }
        return false;
    }

    /// Whether a circle of the given radius at p hits scenery or leaves the arena.
    pub fn blocked(self: *const World, p: rl.Vector3, radius: f32) bool {
        if (@abs(p.x) > self.HalfW - radius or @abs(p.z) > self.HalfD - radius) return true;
        for (self.obs()) |o| {
            const rr = o.Radius + radius;
            if (dist2XZ(o.Pos, p) < rr * rr) return true;
        }
        return false;
    }

    // Passable when clear of scenery AND the height change is within STEP_MAX —
    // cliff faces are walls, ramps are gradual.
    fn passable(self: *const World, p: rl.Vector3, radius: f32, fromY: f32) bool {
        if (self.blocked(p, radius)) return false;
        return @abs(self.groundY(p.x, p.z) - fromY) <= STEP_MAX;
    }

    /// Move by delta, sliding along obstacles (full, then X-only, then Z-only). The
    /// result carries the correct ground height in y.
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

    /// Whether a projectile at p hit blocking scenery (a shot above an obstacle
    /// clears it), the arena edge, or terrain (a bolt below a ledge top splats on
    /// its side — cliff faces are cover).
    pub fn rayHitsObstacle(self: *const World, p: rl.Vector3, radius: f32) bool {
        if (@abs(p.x) > self.HalfW or @abs(p.z) > self.HalfD) return true;
        if (self.groundY(p.x, p.z) > p.y) return true;
        for (self.obs()) |o| {
            if (o.Height < 1.0) continue;
            if (p.y > o.Pos.y + o.Height + 0.3) continue;
            const rr = o.Radius + radius;
            if (dist2XZ(o.Pos, p) < rr * rr) return true;
        }
        return false;
    }

    /// Terrain-aware mouse picking: intersect the ray with floor, every ledge top,
    /// and every ramp plane; return the NEAREST hit that lies on its surface (a
    /// click on a rampart lands on the rampart, not the floor beneath it).
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
                if (hit.t < bestT and l.contains(hit.p.x, hit.p.z)) {
                    bestT = hit.t;
                    best = hit.p;
                }
            }
        }
        for (self.rmp()) |r| {
            const k = r.planeCoeffs();
            if (rayAtPlane(ray, k[0], k[1], k[2])) |hit| {
                if (hit.t < bestT and r.contains(hit.p.x, hit.p.z)) {
                    bestT = hit.t;
                    best = hit.p;
                }
            }
        }
        return best;
    }
};

// Ray vs. plane y = kx*x + kz*z + c (horizontal when kx=kz=0).
fn rayAtPlane(ray: rl.Ray, kx: f32, kz: f32, c: f32) ?struct { p: rl.Vector3, t: f32 } {
    const denom = ray.direction.y - kx * ray.direction.x - kz * ray.direction.z;
    if (@abs(denom) < 1e-6) return null;
    const t = (kx * ray.position.x + kz * ray.position.z + c - ray.position.y) / denom;
    if (t < 0) return null;
    const x = ray.position.x + ray.direction.x * t;
    const z = ray.position.z + ray.direction.z * t;
    return .{ .p = v3(x, kx * x + kz * z + c, z), .t = t };
}

// Worlds are AUTHORED: areas come from maps/*.map (map.zig); procgen was exported
// into the starter maps once and removed. map.toWorld() is the only World constructor.
