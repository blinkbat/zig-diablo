const std = @import("std");
const rl = @import("raylib");

// Gameplay math on the XZ ground plane (Y up); these helpers ignore Y. (From util.go.)

/// Vector3 constructor shorthand: v3(x, y, z).
pub const v3 = rl.Vector3.init;
/// Color constructor shorthand: rgba(r, g, b, a).
pub const rgba = rl.Color.init;
/// The zero vector — used as a struct-field default (Go's zero value).
pub const zero3 = rl.Vector3{ .x = 0, .y = 0, .z = 0 };

pub fn clampF(v: f32, lo: f32, hi: f32) f32 {
    // NaN passes both `<` and `>`, so it'd escape unclamped and blow up a downstream
    // @intFromFloat; pin it to lo (safe, no meaningful clamp position for NaN).
    if (std.math.isNan(v)) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

pub fn clampI(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

pub fn maxF(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

pub fn minF(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// A position on the floor plane.
pub fn ground(x: f32, z: f32) rl.Vector3 {
    return v3(x, 0, z);
}

/// Horizontal distance between two points (Y ignored).
pub fn distXZ(a: rl.Vector3, b: rl.Vector3) f32 {
    const dx = a.x - b.x;
    const dz = a.z - b.z;
    return @sqrt(dx * dx + dz * dz);
}

/// Squared horizontal distance (Y ignored); compare vs a squared radius to skip
/// the @sqrt on hot collision scans.
pub fn dist2XZ(a: rl.Vector3, b: rl.Vector3) f32 {
    const dx = a.x - b.x;
    const dz = a.z - b.z;
    return dx * dx + dz * dz;
}

/// Unit direction from a to b in the XZ plane (zero if coincident).
pub fn dirXZ(from: rl.Vector3, to: rl.Vector3) rl.Vector3 {
    const dx = to.x - from.x;
    const dz = to.z - from.z;
    const d = @sqrt(dx * dx + dz * dz);
    if (d < 1e-5) return v3(0, 0, 0);
    return v3(dx / d, 0, dz / d);
}

pub fn lenXZ(v: rl.Vector3) f32 {
    return @sqrt(v.x * v.x + v.z * v.z);
}

/// Right-hand perpendicular of a facing direction in the XZ plane.
pub fn perpXZ(f: rl.Vector3) rl.Vector3 {
    return v3(f.z, 0, -f.x);
}

/// Returns f if it has a horizontal heading, else the fallback (fx, fz).
pub fn orFacing(f: rl.Vector3, fx: f32, fz: f32) rl.Vector3 {
    if (lenXZ(f) < 1e-3) return v3(fx, 0, fz);
    return f;
}

/// A copy of col with the given alpha (0..255).
pub fn withAlpha(col: rl.Color, a: u8) rl.Color {
    var out = col;
    out.a = a;
    return out;
}

/// Clamp a float to [0,255] and narrow to u8 (channel/alpha math).
pub fn u8f(v: f32) u8 {
    return @intFromFloat(clampF(v, 0, 255));
}

/// sin/cos on f32, computed via f64 (mirrors Go's float32(math.Sin(float64(x)))).
pub fn sinf(x: f32) f32 {
    return @floatCast(@sin(@as(f64, x)));
}
pub fn cosf(x: f32) f32 {
    return @floatCast(@cos(@as(f64, x)));
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return u8f(af + (bf - af) * t);
}

/// Linearly interpolate between two colors.
pub fn lerpColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const tt = clampF(t, 0, 1);
    return rgba(
        lerpU8(a.r, b.r, tt),
        lerpU8(a.g, b.g, tt),
        lerpU8(a.b, b.b, tt),
        lerpU8(a.a, b.a, tt),
    );
}

/// Seeded RNG wrapper mirroring the subset of Go's math/rand the game used.
pub const Rng = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Rng {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn rand(self: *Rng) std.Random {
        return self.prng.random();
    }

    /// [0,1) f32 — Go's rng.Float32().
    pub fn float(self: *Rng) f32 {
        return self.rand().float(f32);
    }

    /// [0,1) f64 — Go's rng.Float64().
    pub fn float64(self: *Rng) f64 {
        return self.rand().float(f64);
    }

    /// Uniform f32 in [lo, hi). Used for damage rolls (min..max).
    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + self.float() * (hi - lo);
    }

    /// [0,n) — Go's rng.Intn(n). Returns 0 for n<=0 (Go would panic).
    pub fn intn(self: *Rng, n: i32) i32 {
        if (n <= 0) return 0;
        return @intCast(self.rand().uintLessThan(u32, @intCast(n)));
    }
};

/// A time-based seed, mirroring Go's time.Now().UnixNano() seeding.
pub fn timeSeed() u64 {
    const ns: u128 = @bitCast(std.time.nanoTimestamp());
    return @truncate(ns);
}
