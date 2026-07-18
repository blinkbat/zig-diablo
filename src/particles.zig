const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");

const v3 = mathx.v3;
const sinf = mathx.sinf;
const cosf = mathx.cosf;

// PARTICLES — one fixed-capacity pool of emissive motes for every transient effect
// (sparks, bursts, firebolt trail, portal motes, level-up rings). Drawn after endScene
// with the default shader, so they glow in the dark and bypass the lighting pipeline.
// When full, the pool overwrites via a ring cursor (swap-remove on death shuffles slot
// order, so it evicts an arbitrary live mote — a dropped spark is invisible either way).

pub const MAX_PARTICLES = 2048;

pub const Particle = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Vel: rl.Vector3 = mathx.zero3,
    Life: f32 = 0,
    maxLife: f32 = 1,
    Size: f32 = 0.1,
    Color: rl.Color = rl.Color.white,
    grav: f32 = 0, // downward pull; negative floats the mote upward
    drag: f32 = 0, // fraction of velocity shed per second
};

pub const Particles = struct {
    buf: [MAX_PARTICLES]Particle = undefined,
    count: usize = 0,
    next: usize = 0, // overwrite cursor once the pool is saturated

    pub fn spawn(self: *Particles, p: Particle) void {
        if (self.count < self.buf.len) {
            self.buf[self.count] = p;
            self.count += 1;
        } else {
            self.buf[self.next] = p;
            self.next = (self.next + 1) % self.buf.len;
        }
    }

    pub fn clear(self: *Particles) void {
        self.count = 0;
        self.next = 0;
    }

    /// Radial burst of `n` motes at `pos`: random dirs, speeds in [speed*0.35, speed],
    /// slight upward bias so bursts bloom rather than pancake.
    pub fn burst(self: *Particles, rng: *mathx.Rng, pos: rl.Vector3, n: usize, speed: f32, size: f32, life: f32, col: rl.Color, grav: f32) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ang = rng.angle();
            const pitch = (rng.float() - 0.25) * 1.6; // biased above the horizon
            const sp = speed * (0.35 + 0.65 * rng.float());
            const cp = cosf(pitch);
            self.spawn(.{
                .Pos = pos,
                .Vel = v3(cosf(ang) * cp * sp, sinf(pitch) * sp + speed * 0.2, sinf(ang) * cp * sp),
                .Life = life * (0.6 + 0.4 * rng.float()),
                .maxLife = life,
                .Size = size * (0.7 + 0.6 * rng.float()),
                .Color = col,
                .grav = grav,
                .drag = 2.5,
            });
        }
    }

    pub fn update(self: *Particles, dt: f32, w: *const world.World) void {
        var i: usize = 0;
        while (i < self.count) {
            const p = &self.buf[i];
            p.Life -= dt;
            if (p.Life <= 0) {
                self.count -= 1;
                self.buf[i] = self.buf[self.count];
                if (self.next > self.count) self.next = 0;
                continue;
            }
            p.Vel.y -= p.grav * dt;
            const k = 1.0 - mathx.clampF(p.drag * dt, 0, 0.9);
            p.Vel.x *= k;
            p.Vel.y *= k;
            p.Vel.z *= k;
            const prevY = p.Pos.y;
            p.Pos.x += p.Vel.x * dt;
            p.Pos.y += p.Vel.y * dt;
            p.Pos.z += p.Vel.z * dt;
            // Rest on the LOCAL floor (heightfield world — sparks on a rampart mustn't
            // fall through its top). Only catch a mote crossing the floor from above;
            // one that drifted sideways under a ledge is already inside the cliff, and
            // snapping it up would read as a teleport. A non-descending mote (Vel.y >= 0)
            // keeps Pos.y >= prevY, so it can't cross downward — skip the heightfield query.
            if (p.Vel.y < 0) {
                const floorY = w.groundY(p.Pos.x, p.Pos.z) + 0.02;
                if (p.Pos.y < floorY and prevY >= floorY) p.Pos.y = floorY;
            }
            i += 1;
        }
    }

    /// Emissive pass: call between endScene and endMode3D. Motes shrink/fade over
    /// their lifetime. 4x4 spheres read as round glow at mote sizes.
    pub fn draw(self: *const Particles) void {
        for (self.buf[0..self.count]) |*p| {
            const f = mathx.clampF(p.Life / p.maxLife, 0, 1);
            const a: f32 = @floatFromInt(p.Color.a);
            rl.drawSphereEx(p.Pos, p.Size * (0.35 + 0.65 * f), 4, 4, mathx.withAlpha(p.Color, mathx.u8f(a * f)));
        }
    }
};
