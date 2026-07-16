const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");

// FOG OF WAR — persistent exploration memory layered under the live torch.
//
// The torch (torchlight.zig) lights a disc around the hero and the scene shader fades
// everything past it to black. Fog adds the middle state: ground ever swept stays
// faintly "seen" (dim, desaturated); never-lit ground is black ("unseen").
//
// One grayscale (R8) texture over the arena XZ plane. Each frame the disc under the
// hero is painted into a CPU grid (monotonic max — once seen never un-reveals),
// re-uploaded when changed, and sampled by the scene shader per fragment for
// unseen/seen/active. Per-area: reset() clears the grid on area entry.

// Grid resolution over the arena square. 256 => 1 world-unit/texel at the largest
// area (half-extent clamps to map.HALF_MAX = 128 in map.sanitize); bilinear softens
// the edge. The 64 KB cell grid still uploads in one updateTexture.
pub const RES = 256;

pub const Fog = struct {
    // Explored per cell, 0 (unseen)..255 (seen), row-major [z*RES + x]. Only
    // increases (max on reveal), so the frontier never fades.
    cells: [RES * RES]u8 = [_]u8{0} ** (RES * RES),
    tex: rl.Texture2D = undefined,
    halfW: f32 = 1, // arena half-extents the grid spans; drive world->UV (kept > 0)
    halfD: f32 = 1,
    dirty: bool = true, // a cell changed (or area is fresh): re-upload pending
    // Last reveal center+radius. The grid is monotonic-max, so re-revealing an unchanged
    // disc writes nothing — skip the whole bbox scan (~hundreds of sqrts) while the hero
    // holds still. Invalidated (lastR = -1) whenever the grid itself changes.
    lastX: f32 = 0,
    lastZ: f32 = 0,
    lastR: f32 = -1,

    pub fn init() Fog {
        // Build the R8 texture once; contents come from `cells` via updateTexture.
        // Black RGBA reformatted to grayscale so size/format match per-frame uploads.
        // Bilinear + clamp: soft frontier, and samples past the arena edge clamp to
        // the border cell instead of wrapping the reveal to the far side.
        var img = rl.genImageColor(RES, RES, rl.Color.black);
        rl.imageFormat(&img, .uncompressed_grayscale);
        const tex = rl.loadTextureFromImage(img) catch @panic("fog texture");
        rl.unloadImage(img);
        rl.setTextureFilter(tex, .bilinear);
        rl.setTextureWrap(tex, .clamp);
        return .{ .tex = tex };
    }

    pub fn deinit(self: *Fog) void {
        rl.unloadTexture(self.tex);
    }

    // New area: forget everything and store the extents to map against.
    pub fn reset(self: *Fog, halfW: f32, halfD: f32) void {
        @memset(&self.cells, 0);
        self.halfW = if (halfW > 0) halfW else 1;
        self.halfD = if (halfD > 0) halfD else 1;
        self.dirty = true;
        self.lastR = -1; // grid cleared — force the next reveal to re-scan
    }

    // Paint the disc of `radius` around ground `pos` into the grid. Cells fade from
    // seen inside `inner` to unseen at the edge, kept as a running max so the frontier
    // keeps a soft edge while cells behind it saturate. Iterates the disc's bbox only.
    pub fn reveal(self: *Fog, pos: rl.Vector3, radius: f32) void {
        if (radius == self.lastR and pos.x == self.lastX and pos.z == self.lastZ) return;
        self.lastX = pos.x;
        self.lastZ = pos.z;
        self.lastR = radius;
        const spanW = self.halfW * 2;
        const spanD = self.halfD * 2;
        const inner = radius * 0.82; // fully seen within this; linear ramp out to `radius`
        const ramp = if (radius > inner) radius - inner else 1;
        const cx0 = cellIndex((pos.x - radius + self.halfW) / spanW);
        const cx1 = cellIndex((pos.x + radius + self.halfW) / spanW);
        const cz0 = cellIndex((pos.z - radius + self.halfD) / spanD);
        const cz1 = cellIndex((pos.z + radius + self.halfD) / spanD);
        var cz = cz0;
        while (cz <= cz1) : (cz += 1) {
            const wz = cellCenterWorld(cz, spanD, self.halfD);
            var cx = cx0;
            while (cx <= cx1) : (cx += 1) {
                const wx = cellCenterWorld(cx, spanW, self.halfW);
                const dx = wx - pos.x;
                const dz = wz - pos.z;
                const d = @sqrt(dx * dx + dz * dz);
                if (d >= radius) continue;
                const val = mathx.u8f(mathx.clampF((radius - d) / ramp, 0, 1) * 255);
                const idx: usize = @intCast(cz * RES + cx);
                if (val > self.cells[idx]) {
                    self.cells[idx] = val;
                    self.dirty = true;
                }
            }
        }
    }

    // Editor mode: whole arena reads as fully seen.
    pub fn revealAll(self: *Fog, halfW: f32, halfD: f32) void {
        @memset(&self.cells, 255);
        self.halfW = if (halfW > 0) halfW else 1;
        self.halfD = if (halfD > 0) halfD else 1;
        self.dirty = true;
        self.lastR = -1; // grid changed — force the next reveal to re-scan
    }

    // Upload the grid to the GPU if it changed since the last sync.
    pub fn sync(self: *Fog) void {
        if (!self.dirty) return;
        rl.updateTexture(self.tex, &self.cells);
        self.dirty = false;
    }
};

// [0,1] arena fraction -> cell index, clamped to the grid. Clamp the FLOAT before
// the cast: @intFromFloat on a NaN/Inf/out-of-range value is illegal (panics in
// safe builds, UB in ReleaseFast), so clampI-after-cast would be too late.
fn cellIndex(frac: f32) i32 {
    return @intFromFloat(mathx.clampF(@floor(frac * RES), 0, RES - 1));
}

// World coordinate of a cell center along one axis (inverse of cellIndex).
fn cellCenterWorld(cell: i32, span: f32, half: f32) f32 {
    return (@as(f32, @floatFromInt(cell)) + 0.5) / RES * span - half;
}
