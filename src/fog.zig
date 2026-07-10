const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");

// FOG OF WAR — the persistent exploration memory layered under the live torch.
//
// The torch (torchlight.zig) lights a disc around the hero every frame: inside it the
// world renders in full ("active"), and the scene shader already fades everything past
// the torch radius to black. Fog supplies the missing middle state: ground the torch
// has ever swept stays faintly visible ("seen" — dim, desaturated terrain), while
// ground the hero has never lit is pure black ("unseen").
//
// Implementation: one grayscale (R8) texture covering the arena's XZ plane. Each frame
// the disc under the hero is painted into a CPU grid (monotonic max, so a place once
// seen never un-reveals), the grid is re-uploaded when it changed, and the scene shader
// samples it at each fragment's ground position to choose unseen/seen/active. Vision is
// per-area: buildWorld makes a fresh layout, so reset() clears the grid on area entry.

// Grid resolution over the arena square. 128 => ~0.75 world-units/texel at the largest
// area (Half=48); bilinear sampling turns the texel steps into a soft seen/unseen edge.
pub const RES = 128;

pub const Fog = struct {
    // Explored amount per cell, 0 (unseen) .. 255 (fully seen), row-major [z*RES + x].
    // Only ever increases (max on reveal), so the frontier the hero reached never fades.
    cells: [RES * RES]u8 = [_]u8{0} ** (RES * RES),
    tex: rl.Texture2D = undefined,
    halfW: f32 = 1, // arena half-extents the grid spans; drive world->UV (kept > 0)
    halfD: f32 = 1,
    dirty: bool = true, // a cell changed (or the area is fresh): re-upload pending

    pub fn init() Fog {
        // Build the R8 texture once; its contents come from `cells` via updateTexture.
        // Start from a black RGBA image reformatted to grayscale so its size/format
        // match the per-frame uploads. Bilinear + clamp: a soft frontier, and samples
        // just past the arena edge (walls sit a hair outside it) clamp to the border
        // cell rather than wrapping the reveal around to the far side.
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

    // Start a new area: forget everything and remember the extents to map against.
    pub fn reset(self: *Fog, halfW: f32, halfD: f32) void {
        @memset(&self.cells, 0);
        self.halfW = if (halfW > 0) halfW else 1;
        self.halfD = if (halfD > 0) halfD else 1;
        self.dirty = true;
    }

    // Paint the disc of the given radius around ground position `pos` into the grid.
    // Cells fade from fully-seen inside `inner` to unseen at the edge; kept as a running
    // max so the outermost frontier the hero ever reached keeps a soft edge while every
    // cell behind it saturates to fully-seen. Iterates only the disc's bounding box.
    pub fn reveal(self: *Fog, pos: rl.Vector3, radius: f32) void {
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

    // Editor mode: no exploration — the whole arena reads as fully seen.
    pub fn revealAll(self: *Fog, halfW: f32, halfD: f32) void {
        @memset(&self.cells, 255);
        self.halfW = if (halfW > 0) halfW else 1;
        self.halfD = if (halfD > 0) halfD else 1;
        self.dirty = true;
    }

    // Upload the grid to the GPU if it changed since the last sync.
    pub fn sync(self: *Fog) void {
        if (!self.dirty) return;
        rl.updateTexture(self.tex, &self.cells);
        self.dirty = false;
    }
};

// Map a [0,1] arena fraction to a valid cell index, clamped to the grid.
fn cellIndex(frac: f32) i32 {
    return mathx.clampI(@intFromFloat(@floor(frac * RES)), 0, RES - 1);
}

// World coordinate of a cell center along one axis (inverse of cellIndex).
fn cellCenterWorld(cell: i32, span: f32, half: f32) f32 {
    return (@as(f32, @floatFromInt(cell)) + 0.5) / RES * span - half;
}
