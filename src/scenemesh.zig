const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const sinf = mathx.sinf;
const cosf = mathx.cosf;

// SCENE MESH — the arena's static geometry (floor, terrain features, boulders,
// gravestones, trees, decor) baked into ONE GPU mesh at area load, instead of
// regenerating hundreds of thousands of vertices on the CPU every frame (shadow +
// main pass) — that regen was the FPS bottleneck. Once uploaded, each pass is a
// single GPU call.
//
// Mesh carries per-vertex tints + outward normals, exactly what torchlight's scene
// shader reads (fragColor + fragNormal). Drawn backface-culling-off so a winding
// mistake can't hide a face.

// c_allocator is malloc, matching raylib's libc free() in UnloadMesh, so ownership
// transfers cleanly after uploadMesh.
const alloc = std.heap.c_allocator;

// FLOOR SENTINELS — the scene shader keys walkable-ground materials off a NEGATIVE
// texcoord u (immediate-mode raylib draws only emit u >= 0, so props can't trip it).
// -1 = the area's blended floor-material field; -2 = forced masonry pavement
// (ledge caps, ramp tops). Must match the branch thresholds in torchlight's sceneFS.
const FLAG_FLOOR: f32 = -1;
const FLAG_PAVE: f32 = -2;

const Builder = struct {
    pos: std.ArrayList(f32),
    nrm: std.ArrayList(f32),
    uv: std.ArrayList(f32),
    col: std.ArrayList(u8),
    uvx: f32 = 0, // current texcoord-u flag; set around floor/pavement bakes, else 0

    fn init() Builder {
        return .{
            .pos = std.ArrayList(f32).init(alloc),
            .nrm = std.ArrayList(f32).init(alloc),
            .uv = std.ArrayList(f32).init(alloc),
            .col = std.ArrayList(u8).init(alloc),
        };
    }

    fn vert(self: *Builder, p: rl.Vector3, n: rl.Vector3, c: rl.Color) void {
        self.pos.appendSlice(&.{ p.x, p.y, p.z }) catch @panic("oom");
        self.nrm.appendSlice(&.{ n.x, n.y, n.z }) catch @panic("oom");
        self.uv.appendSlice(&.{ self.uvx, 0 }) catch @panic("oom");
        self.col.appendSlice(&.{ c.r, c.g, c.b, c.a }) catch @panic("oom");
    }

    // A quad a→b→c→d with one shared (flat) normal, as two triangles.
    fn quad(self: *Builder, a: rl.Vector3, b: rl.Vector3, c: rl.Vector3, d: rl.Vector3, n: rl.Vector3, col: rl.Color) void {
        self.vert(a, n, col);
        self.vert(b, n, col);
        self.vert(c, n, col);
        self.vert(a, n, col);
        self.vert(c, n, col);
        self.vert(d, n, col);
    }

    fn addSphere(self: *Builder, center: rl.Vector3, radius: f32, rings: i32, slices: i32, col: rl.Color) void {
        const rf: f32 = @floatFromInt(rings);
        const sf: f32 = @floatFromInt(slices);
        var i: i32 = 0;
        while (i < rings) : (i += 1) {
            const lat0 = std.math.pi * (@as(f32, @floatFromInt(i)) / rf - 0.5);
            const lat1 = std.math.pi * (@as(f32, @floatFromInt(i + 1)) / rf - 0.5);
            var j: i32 = 0;
            while (j < slices) : (j += 1) {
                const lon0 = 2 * std.math.pi * @as(f32, @floatFromInt(j)) / sf;
                const lon1 = 2 * std.math.pi * @as(f32, @floatFromInt(j + 1)) / sf;
                const n00 = spherePt(lat0, lon0);
                const n01 = spherePt(lat0, lon1);
                const n10 = spherePt(lat1, lon0);
                const n11 = spherePt(lat1, lon1);
                // Smooth normals = radial dir; positions = center + n*radius.
                self.vert(scaleAdd(center, n00, radius), n00, col);
                self.vert(scaleAdd(center, n10, radius), n10, col);
                self.vert(scaleAdd(center, n11, radius), n11, col);
                self.vert(scaleAdd(center, n00, radius), n00, col);
                self.vert(scaleAdd(center, n11, radius), n11, col);
                self.vert(scaleAdd(center, n01, radius), n01, col);
            }
        }
    }

    fn addCube(self: *Builder, center: rl.Vector3, size: rl.Vector3, col: rl.Color) void {
        const hx = size.x / 2;
        const hy = size.y / 2;
        const hz = size.z / 2;
        const cx = center.x;
        const cy = center.y;
        const cz = center.z;
        // +X / -X
        self.quad(v3(cx + hx, cy - hy, cz - hz), v3(cx + hx, cy - hy, cz + hz), v3(cx + hx, cy + hy, cz + hz), v3(cx + hx, cy + hy, cz - hz), v3(1, 0, 0), col);
        self.quad(v3(cx - hx, cy - hy, cz + hz), v3(cx - hx, cy - hy, cz - hz), v3(cx - hx, cy + hy, cz - hz), v3(cx - hx, cy + hy, cz + hz), v3(-1, 0, 0), col);
        // +Y / -Y
        self.quad(v3(cx - hx, cy + hy, cz - hz), v3(cx + hx, cy + hy, cz - hz), v3(cx + hx, cy + hy, cz + hz), v3(cx - hx, cy + hy, cz + hz), v3(0, 1, 0), col);
        self.quad(v3(cx - hx, cy - hy, cz + hz), v3(cx + hx, cy - hy, cz + hz), v3(cx + hx, cy - hy, cz - hz), v3(cx - hx, cy - hy, cz - hz), v3(0, -1, 0), col);
        // +Z / -Z
        self.quad(v3(cx - hx, cy - hy, cz + hz), v3(cx - hx, cy + hy, cz + hz), v3(cx + hx, cy + hy, cz + hz), v3(cx + hx, cy - hy, cz + hz), v3(0, 0, 1), col);
        self.quad(v3(cx + hx, cy - hy, cz - hz), v3(cx + hx, cy + hy, cz - hz), v3(cx - hx, cy + hy, cz - hz), v3(cx - hx, cy - hy, cz - hz), v3(0, 0, -1), col);
    }

    // Parallelepiped from a center and three half-axis vectors — the oriented cousin
    // of addCube (which stays axis-aligned). Face normals are the normalized axes:
    // exact for orthogonal axes, near enough for the slight shears rocks use.
    fn addBox(self: *Builder, c: rl.Vector3, ax: rl.Vector3, ay: rl.Vector3, az: rl.Vector3, col: rl.Color) void {
        const corner = struct {
            fn at(cc: rl.Vector3, x: rl.Vector3, y: rl.Vector3, z: rl.Vector3, sx: f32, sy: f32, sz: f32) rl.Vector3 {
                return v3(cc.x + x.x * sx + y.x * sy + z.x * sz, cc.y + x.y * sx + y.y * sy + z.y * sz, cc.z + x.z * sx + y.z * sy + z.z * sz);
            }
        }.at;
        // ±ax / ±ay / ±az faces, each a quad of the four corners sharing that sign.
        self.quad(corner(c, ax, ay, az, 1, -1, -1), corner(c, ax, ay, az, 1, -1, 1), corner(c, ax, ay, az, 1, 1, 1), corner(c, ax, ay, az, 1, 1, -1), norm(ax), col);
        self.quad(corner(c, ax, ay, az, -1, -1, 1), corner(c, ax, ay, az, -1, -1, -1), corner(c, ax, ay, az, -1, 1, -1), corner(c, ax, ay, az, -1, 1, 1), norm(neg(ax)), col);
        self.quad(corner(c, ax, ay, az, -1, 1, -1), corner(c, ax, ay, az, 1, 1, -1), corner(c, ax, ay, az, 1, 1, 1), corner(c, ax, ay, az, -1, 1, 1), norm(ay), col);
        self.quad(corner(c, ax, ay, az, -1, -1, 1), corner(c, ax, ay, az, 1, -1, 1), corner(c, ax, ay, az, 1, -1, -1), corner(c, ax, ay, az, -1, -1, -1), norm(neg(ay)), col);
        self.quad(corner(c, ax, ay, az, -1, -1, 1), corner(c, ax, ay, az, -1, 1, 1), corner(c, ax, ay, az, 1, 1, 1), corner(c, ax, ay, az, 1, -1, 1), norm(az), col);
        self.quad(corner(c, ax, ay, az, 1, -1, -1), corner(c, ax, ay, az, 1, 1, -1), corner(c, ax, ay, az, -1, 1, -1), corner(c, ax, ay, az, -1, -1, -1), norm(neg(az)), col);
    }

    // Tapered cylinder wall (no caps) from `a` (radius ra) to `b` (radius rb).
    fn addCylinder(self: *Builder, a: rl.Vector3, b: rl.Vector3, ra: f32, rb: f32, sides: i32, col: rl.Color) void {
        const axis = norm(v3(b.x - a.x, b.y - a.y, b.z - a.z));
        // A vector not parallel to axis, to build a perpendicular basis.
        const seed = if (@abs(axis.y) < 0.99) v3(0, 1, 0) else v3(1, 0, 0);
        const u = norm(cross(axis, seed));
        const w = norm(cross(axis, u));
        const sf: f32 = @floatFromInt(sides);
        var s: i32 = 0;
        while (s < sides) : (s += 1) {
            const a0 = 2 * std.math.pi * @as(f32, @floatFromInt(s)) / sf;
            const a1 = 2 * std.math.pi * @as(f32, @floatFromInt(s + 1)) / sf;
            const d0 = dirOn(u, w, a0);
            const d1 = dirOn(u, w, a1);
            const p0 = scaleAdd(a, d0, ra);
            const p1 = scaleAdd(a, d1, ra);
            const p2 = scaleAdd(b, d1, rb);
            const p3 = scaleAdd(b, d0, rb);
            const nmid = norm(v3(d0.x + d1.x, d0.y + d1.y, d0.z + d1.z));
            self.quad(p0, p1, p2, p3, nmid, col);
        }
    }

};

fn spherePt(lat: f32, lon: f32) rl.Vector3 {
    const cl = cosf(lat);
    return v3(cl * cosf(lon), sinf(lat), cl * sinf(lon));
}
fn scaleAdd(base: rl.Vector3, dir: rl.Vector3, s: f32) rl.Vector3 {
    return v3(base.x + dir.x * s, base.y + dir.y * s, base.z + dir.z * s);
}
fn dirOn(u: rl.Vector3, w: rl.Vector3, ang: f32) rl.Vector3 {
    const c = cosf(ang);
    const s = sinf(ang);
    return v3(u.x * c + w.x * s, u.y * c + w.y * s, u.z * c + w.z * s);
}
fn neg(a: rl.Vector3) rl.Vector3 {
    return v3(-a.x, -a.y, -a.z);
}
fn norm(a: rl.Vector3) rl.Vector3 {
    const l = @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    if (l < 1e-6) return v3(0, 1, 0);
    return v3(a.x / l, a.y / l, a.z / l);
}
fn cross(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

// ---- Obstacle shapes (same geometry as the immediate-mode versions, baked once) ----

// Every bake offsets geometry by Pos.y — props on a rampart bake at rampart height
// (map.toWorld snaps Pos.y to the terrain).

fn bakeBoulder(b: *Builder, o: world.Obstacle) void {
    const gy = o.Pos.y;
    const x = o.Pos.x;
    const z = o.Pos.z;
    const r = o.Radius;
    // Stone dragged hard toward wet earth: half-sunk moor rock, not clean quarry
    // grey (0.40 — the old 0.28 still glared near the torch core).
    const grime = lerpColor(o.Tint, rgba(38, 34, 28, 255), 0.40);
    // Three rock silhouettes, deterministic from position (same field every load):
    // 0 = the rounded family cluster, 1 = a canted angular slab, 2 = a rubble spill.
    const seed = x * 7.7 + z * 4.1;
    const vroll = @abs(sinf(seed * 7.31));
    if (vroll < 0.5) {
        b.addSphere(v3(x, gy + o.Height * 0.35, z), r, 8, 8, grime);
        b.addSphere(v3(x + r * 0.4, gy + o.Height * 0.22, z + r * 0.3), r * 0.6, 8, 8, lerpColor(grime, rl.Color.black, 0.15));
        // A shed chip against the parent stone: boulders come in families.
        b.addSphere(v3(x - r * 0.85, gy + r * 0.16, z - r * 0.45), r * 0.28, 6, 6, lerpColor(grime, rl.Color.white, 0.04));
    } else if (vroll < 0.78) {
        // Canted slab, half-buried: a broken monolith heaved LOW out of the moor —
        // wide and flat, not a standing crate. The tilted up-axis shears the box;
        // addBox normals tolerate it.
        const ca = cosf(seed);
        const sa = sinf(seed);
        const tilt = 0.45 * sinf(seed * 3.1);
        const hh = @min(o.Height * 0.30, r * 0.55); // slab thickness stays rock-flat
        const ax = v3(ca * r * 1.30, 0, sa * r * 1.30);
        const az = v3(-sa * r * 0.80, 0, ca * r * 0.80);
        const ay = v3(-sa * tilt * hh, hh, ca * tilt * hh);
        b.addBox(v3(x, gy + hh * 0.55, z), ax, ay, az, grime);
        b.addSphere(v3(x + ca * r * 0.7, gy + r * 0.14, z + sa * r * 0.7), r * 0.30, 6, 6, lerpColor(grime, rl.Color.black, 0.12));
    } else {
        // Rubble spill: no single mass, just a low heap of fragments.
        var i: i32 = 0;
        while (i < 5) : (i += 1) {
            const iff: f32 = @floatFromInt(i);
            const ang = seed + iff * 2.4;
            const dd = r * (0.15 + 0.45 * @abs(sinf(seed * 1.7 + iff)));
            const rr = r * (0.30 + 0.22 * @abs(sinf(seed + iff * 3.3)));
            const tone = lerpColor(grime, rl.Color.black, 0.06 * iff);
            b.addSphere(v3(x + cosf(ang) * dd, gy + rr * 0.55, z + sinf(ang) * dd), rr, 6, 6, tone);
        }
    }
}

fn bakeGravestone(b: *Builder, o: world.Obstacle) void {
    // Slab + a rounded top RIDGE (horizontal cylinder matching slab width/thickness;
    // a full sphere ballooned past the faces into a lollipop) + a foot plinth.
    const gy = o.Pos.y;
    const dark = lerpColor(o.Tint, rl.Color.black, 0.3);
    const ridge_r = 0.19; // rounded-top ridge: cylinder + its two end-cap spheres must match
    b.addCube(v3(o.Pos.x, gy + o.Height / 2, o.Pos.z), v3(o.Radius * 2, o.Height, 0.35), o.Tint);
    b.addCylinder(v3(o.Pos.x - o.Radius, gy + o.Height, o.Pos.z), v3(o.Pos.x + o.Radius, gy + o.Height, o.Pos.z), ridge_r, ridge_r, 8, o.Tint);
    b.addSphere(v3(o.Pos.x - o.Radius, gy + o.Height, o.Pos.z), ridge_r, 6, 6, o.Tint);
    b.addSphere(v3(o.Pos.x + o.Radius, gy + o.Height, o.Pos.z), ridge_r, 6, 6, o.Tint);
    b.addCube(v3(o.Pos.x, gy + 0.14, o.Pos.z), v3(o.Radius * 2 + 0.3, 0.28, 0.62), dark);
}

fn bakeTree(b: *Builder, o: world.Obstacle) void {
    const bark = o.Tint;
    const x = o.Pos.x;
    const z = o.Pos.z;
    const gy = o.Pos.y;
    const segs_n = 4;
    // Three silhouettes, deterministic from position so authored woods are stable:
    // 0 = the gnarled leaner, 1 = a DEAD bare claw (no canopy), 2 = a fuller crown.
    const seed = x * 5.1 + z * 3.7;
    const vroll = @abs(sinf(seed * 12.9898));
    const dead = vroll >= 0.45 and vroll < 0.75;
    const full = vroll >= 0.75;
    // Per-tree lean: every trunk bows its own way and amount; the dead ones bow
    // hardest, the full-crowned ones barely.
    const leanMag: f32 = if (dead) 0.16 + 0.15 * @abs(sinf(seed * 1.3)) else if (full) 0.05 else 0.10 + 0.11 * @abs(sinf(seed * 1.3));
    const lean = v3(cosf(seed) * leanMag, 0, sinf(seed) * leanMag);
    // Root flares gripping the ground: old trees don't rise from a clean socket.
    const rootCol = lerpColor(bark, rl.Color.black, 0.25);
    var r: i32 = 0;
    while (r < 4) : (r += 1) {
        const rf: f32 = @floatFromInt(r);
        const ang = rf * (std.math.tau / 4.0) + o.Height * 1.7;
        const reach = 0.5 + 0.18 * sinf(o.Height * 3 + rf * 2.1);
        b.addCylinder(v3(x, gy + 0.32, z), v3(x + cosf(ang) * reach, gy + 0.02, z + sinf(ang) * reach), 0.15, 0.045, 5, rootCol);
    }
    const trunk_r = 0.38; // trunk base radius, tapering up the segments
    // Dead trunks spend more of the authored height as bare wood (no crown above).
    const trunkH = o.Height * @as(f32, if (dead) 0.78 else 0.62);
    var prev = v3(x, gy, z);
    var i: i32 = 1;
    while (i <= segs_n) : (i += 1) {
        const f: f32 = @as(f32, @floatFromInt(i)) / segs_n;
        const top = v3(x + lean.x * o.Height * f * f, gy + trunkH * f, z + lean.z * o.Height * f * f);
        const r0 = trunk_r * (1 - 0.6 * @as(f32, @floatFromInt(i - 1)) / segs_n);
        const r1 = trunk_r * (1 - 0.6 * f);
        b.addCylinder(prev, top, r0, r1, 8, bark);
        prev = top;
    }
    const crown = prev;

    // Branches claw long and low — some dip below the crown — so bare wood breaks
    // the canopy line. Dead trees carry more, longer, thinner claws; full crowns
    // tuck theirs mostly inside the foliage.
    const branchCol = lerpColor(bark, rl.Color.black, 0.2);
    const brN: i32 = if (dead) 8 else 6;
    const brNf: f32 = @floatFromInt(brN);
    const brLen: f32 = if (dead) 0.95 else if (full) 0.40 else 0.55;
    var j: i32 = 0;
    while (j < brN) : (j += 1) {
        const jf: f32 = @floatFromInt(j);
        const ang = jf * (std.math.tau / brNf) + seed;
        const out = brLen + 0.35 * sinf(o.Height + jf * 1.9);
        const tip = v3(crown.x + cosf(ang) * out, crown.y + 0.15 + 0.35 * sinf(jf * 2.3 + seed), crown.z + sinf(ang) * out);
        b.addCylinder(crown, tip, if (dead) 0.12 else 0.16, 0.03, 5, branchCol);
        if (dead) {
            // A second kinked segment past each claw: the skeleton-hand silhouette.
            const t2 = v3(tip.x + cosf(ang + 0.9) * out * 0.45, tip.y + 0.22 * sinf(jf + seed * 2.0), tip.z + sinf(ang + 0.9) * out * 0.45);
            b.addCylinder(tip, t2, 0.05, 0.0, 4, branchCol);
        }
    }
    if (dead) return; // bare claw: no foliage at all

    // Deep forest green. The scene shader's output gamma (pow 1/2.2) lifts dark
    // albedos hard, so the canopy starts near-black to read as rich green, not sage.
    const canopy = lerpColor(o.Tint, rgba(10, 20, 12, 255), 0.9);
    const cr = o.Radius * @as(f32, if (full) 1.3 else 1.05);
    // Crown mass sags toward the lean and clumps unevenly: a lopsided, half-dead
    // silhouette instead of a topiary ball. Full crowns sit rounder and denser.
    const cc = v3(crown.x + lean.x * 2.2, crown.y + 0.42, crown.z + lean.z * 2.2);
    b.addSphere(cc, cr, 8, 8, canopy);
    const clumps: i32 = if (full) 6 else 5;
    const clumpsF: f32 = @floatFromInt(clumps);
    var k: i32 = 0;
    while (k < clumps) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ang = kf * (std.math.tau / clumpsF) + o.Height + seed;
        const dropY: f32 = if (full) 0.02 + 0.20 * sinf(kf * 1.7 + seed) else 0.05 + 0.38 * sinf(kf * 1.7 + seed);
        const cp = v3(cc.x + cosf(ang) * cr * 0.78, cc.y + dropY, cc.z + sinf(ang) * cr * 0.78);
        b.addSphere(cp, cr * (0.52 + 0.22 * @abs(sinf(kf + seed))), 8, 8, canopy);
    }
}

// ---- Ground decor (non-blocking dressing; see world.Decor) ----

fn bakePebble(b: *Builder, d: world.Decor) void {
    // Sunk to ~40% so it reads as half-buried.
    b.addSphere(v3(d.Pos.x, d.Pos.y + d.Size * 0.4, d.Pos.z), d.Size, 6, 6, d.Tint);
}

fn bakeTuft(b: *Builder, d: world.Decor) void {
    // Grass blades arcing from a common root: each is TWO segments (stiff below,
    // drooping above) so it curves like grass, dark at root, bleached at tip.
    // Per-tuft variation is deterministic from position (no bake-time rng).
    const seed = d.Pos.x * 3.7 + d.Pos.z * 5.3;
    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const ang = iff * (std.math.tau / 5.0) + seed;
        const lean = 0.35 + 0.25 * sinf(seed * 2 + iff * 1.7);
        const h = d.Size * (0.85 + 0.4 * sinf(seed + iff));
        const dx = cosf(ang);
        const dz = sinf(ang);
        const root = v3(d.Pos.x, d.Pos.y, d.Pos.z);
        const mid = v3(d.Pos.x + dx * lean * d.Size * 0.4, d.Pos.y + h * 0.62, d.Pos.z + dz * lean * d.Size * 0.4);
        const tip = v3(d.Pos.x + dx * lean * d.Size * 1.15, d.Pos.y + h * 0.94, d.Pos.z + dz * lean * d.Size * 1.15);
        const rootCol = lerpColor(d.Tint, rl.Color.black, 0.3);
        // Tips bleach toward dead straw, not spring green: moor grass died standing.
        const tipCol = lerpColor(d.Tint, rgba(150, 138, 88, 255), 0.5 + 0.12 * @mod(iff, 2.0));
        b.addCylinder(root, mid, 0.055 * (0.8 + d.Size), 0.03, 3, rootCol);
        b.addCylinder(mid, tip, 0.03, 0.0, 3, tipCol);
    }
}

fn bakeShroom(b: *Builder, d: world.Decor) void {
    const stemH = d.Size * 1.1;
    // Corpse-pale stem, cap dragged toward rot: graveyard fungus, not a fairy ring.
    const cap = lerpColor(d.Tint, rgba(58, 48, 38, 255), 0.4);
    b.addCylinder(v3(d.Pos.x, d.Pos.y, d.Pos.z), v3(d.Pos.x, d.Pos.y + stemH, d.Pos.z), d.Size * 0.22, d.Size * 0.16, 5, rgba(168, 158, 138, 255));
    b.addSphere(v3(d.Pos.x, d.Pos.y + stemH, d.Pos.z), d.Size * 0.55, 6, 6, cap);
}

fn bakeBigShroom(b: *Builder, d: world.Decor) void {
    // Oversized graveyard fungus (Size ~0.7-1.4). Three growth habits, deterministic
    // from position: 0 = fat toadstool, 1 = tall crooked corpse-finger, 2 = a leaning
    // pair. Tint (rot tone) comes from map.decorTint; the stem bleaches paler.
    const seed = d.Pos.x * 3.3 + d.Pos.z * 7.9;
    const vroll = @abs(sinf(seed * 5.77));
    const stem = lerpColor(d.Tint, rgba(152, 142, 120, 255), 0.55);
    if (vroll < 0.45) {
        bakeToadstool(b, d.Pos, d.Size, seed, d.Tint, stem);
    } else if (vroll < 0.75) {
        // Corpse-finger: a two-segment crooked stalk with a small drooped cap.
        const s = d.Size;
        const ang = seed * 1.7;
        const lx = cosf(ang) * 0.30 * s;
        const lz = sinf(ang) * 0.30 * s;
        const mid = v3(d.Pos.x + lx, d.Pos.y + s * 1.1, d.Pos.z + lz);
        const top = v3(d.Pos.x + lx * 2.6, d.Pos.y + s * 1.9, d.Pos.z + lz * 2.6);
        b.addCylinder(v3(d.Pos.x, d.Pos.y, d.Pos.z), mid, s * 0.16, s * 0.12, 5, stem);
        b.addCylinder(mid, top, s * 0.12, s * 0.08, 5, stem);
        b.addSphere(v3(top.x + lx * 0.6, top.y + s * 0.06, top.z + lz * 0.6), s * 0.30, 6, 6, d.Tint);
    } else {
        // Leaning pair: a big and a small toadstool tilted apart, one clump.
        const ang = seed * 2.3;
        const dx = cosf(ang) * d.Size * 0.42;
        const dz = sinf(ang) * d.Size * 0.42;
        bakeToadstool(b, v3(d.Pos.x + dx, d.Pos.y, d.Pos.z + dz), d.Size * 0.8, seed, d.Tint, stem);
        bakeToadstool(b, v3(d.Pos.x - dx, d.Pos.y, d.Pos.z - dz), d.Size * 0.55, seed + 4.1, lerpColor(d.Tint, rl.Color.black, 0.12), stem);
    }
}

// One fat toadstool: thick stem, wide flattened cap (tapered cylinder + low dome),
// a few pale warts. Shared by the bigshroom habits.
fn bakeToadstool(b: *Builder, pos: rl.Vector3, s: f32, seed: f32, cap: rl.Color, stem: rl.Color) void {
    const stemH = s * 0.9;
    const capBase = v3(pos.x, pos.y + stemH, pos.z);
    b.addCylinder(v3(pos.x, pos.y, pos.z), capBase, s * 0.26, s * 0.18, 6, stem);
    // Cap: wide skirt tapering up, closed by a shallow dome — flat and heavy, not
    // a lollipop ball. The skirt underside rim reads as gills in the torch shadow.
    const gill = lerpColor(cap, rl.Color.black, 0.4);
    b.addCylinder(capBase, v3(pos.x, pos.y + stemH + s * 0.34, pos.z), s * 0.78, s * 0.30, 8, cap);
    b.addCylinder(v3(pos.x, pos.y + stemH - s * 0.02, pos.z), capBase, s * 0.72, s * 0.78, 8, gill);
    b.addSphere(v3(pos.x, pos.y + stemH + s * 0.30, pos.z), s * 0.32, 6, 6, cap);
    // Warts: pale flecks scattered on the skirt.
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const wa = seed + iff * 2.2;
        const wr = s * (0.35 + 0.18 * @abs(sinf(seed + iff)));
        b.addSphere(v3(pos.x + cosf(wa) * wr, pos.y + stemH + s * (0.16 + 0.05 * iff), pos.z + sinf(wa) * wr), s * 0.07, 4, 4, lerpColor(cap, rl.Color.white, 0.35));
    }
}

fn bakeBone(b: *Builder, d: world.Decor) void {
    // Two crossed knob-ended shafts lying just proud of the dirt. Per-scatter
    // variation is deterministic from position.
    const seed = d.Pos.x * 7.1 + d.Pos.z * 3.3;
    var i: i32 = 0;
    while (i < 2) : (i += 1) {
        const iff: f32 = @floatFromInt(i);
        const ang = seed + iff * 2.1;
        const half = d.Size * (0.7 + 0.25 * sinf(seed + iff * 1.7));
        const a = v3(d.Pos.x - cosf(ang) * half, d.Pos.y + 0.05, d.Pos.z - sinf(ang) * half);
        const c = v3(d.Pos.x + cosf(ang) * half, d.Pos.y + 0.07 + iff * 0.04, d.Pos.z + sinf(ang) * half);
        b.addCylinder(a, c, 0.04, 0.04, 4, d.Tint);
        b.addSphere(a, 0.06, 5, 5, d.Tint);
        b.addSphere(c, 0.06, 5, 5, d.Tint);
    }
}

// ---- Terrain features (floor + ledges + ramps; see world.zig TERRAIN) ----

// The walkable floor itself: one arena-spanning quad at y=0, flagged FLAG_FLOOR so
// the scene shader paints the area's blended material field over it. Replaces the
// old per-map tinted drawPlane (vertex color stays white — materials own the look).
fn bakeFloor(b: *Builder, w: *const world.World) void {
    b.uvx = FLAG_FLOOR;
    b.quad(v3(-w.HalfW, 0, -w.HalfD), v3(-w.HalfW, 0, w.HalfD), v3(w.HalfW, 0, w.HalfD), v3(w.HalfW, 0, -w.HalfD), v3(0, 1, 0), rl.Color.white);
    b.uvx = 0;
}

fn bakeLedge(b: *Builder, l: world.Ledge) void {
    const cx = (l.minX + l.maxX) / 2;
    const cz = (l.minZ + l.maxZ) / 2;
    const sx = l.maxX - l.minX;
    const sz = l.maxZ - l.minZ;
    // Masonry profile: body, overhanging capstone, darker foot plinth. The cap is
    // FLAG_PAVE: the shader lays stone-slab pavement over it (the walkway must read
    // as GROUND you fight on, so the material system owns it, not a flat tint).
    const body = world.MASONRY;
    const plinth = lerpColor(body, rl.Color.black, 0.35);
    b.addCube(v3(cx, l.h / 2, cz), v3(sx, l.h, sz), body);
    b.uvx = FLAG_PAVE;
    b.addCube(v3(cx, l.h + 0.07, cz), v3(sx + 0.3, 0.14, sz + 0.3), rl.Color.white);
    b.uvx = 0;
    b.addCube(v3(cx, 0.15, cz), v3(sx + 0.2, 0.3, sz + 0.2), plinth);
}

fn bakeRamp(b: *Builder, r: world.Ramp) void {
    const k = r.planeCoeffs(); // gradient for the top-face normal below
    const side = lerpColor(world.MASONRY, rl.Color.black, 0.2);
    // Rect corners, CCW from above, each lifted to its true ramp-top height (via the
    // shared Ramp.heightAt, so the mesh sits exactly on the walkable surface).
    const cs = [_][2]f32{
        .{ r.minX, r.minZ }, .{ r.maxX, r.minZ },
        .{ r.maxX, r.maxZ }, .{ r.minX, r.maxZ },
    };
    var top: [4]rl.Vector3 = undefined;
    for (cs, 0..) |c, i| {
        top[i] = v3(c[0], r.heightAt(c[0], c[1]) + 0.02, c[1]);
    }
    // Top surface: one planar quad, normal = plane gradient — FLAG_PAVE so the shader
    // lays the same stone pavement as ledge caps over the walkable slope.
    b.uvx = FLAG_PAVE;
    b.quad(top[0], top[3], top[2], top[1], norm(v3(-k[0], 1, -k[1])), rl.Color.white);
    b.uvx = 0;
    // Skirt walls to the floor on all four sides (zero-height edges emit harmless
    // degenerate triangles, keeping the loop uniform).
    const outN = [_]rl.Vector3{ v3(0, 0, -1), v3(1, 0, 0), v3(0, 0, 1), v3(-1, 0, 0) };
    for (0..4) |i| {
        const j = (i + 1) % 4;
        const bi = v3(top[i].x, 0, top[i].z);
        const bj = v3(top[j].x, 0, top[j].z);
        b.quad(bi, bj, top[j], top[i], outN[i], side);
    }
}

// Baked mesh plus its backing CPU arrays. After uploadMesh copies to GPU buffers we
// detach the mesh's CPU pointers (raylib's unloadMesh would libc-free them) and free
// them ourselves in deinit/rebuild.
const Baked = struct {
    mesh: rl.Mesh,
    pos: []f32,
    nrm: []f32,
    uv: []f32,
    col: []u8,
};

fn bakeMesh(w: *const world.World) Baked {
    var b = Builder.init();
    bakeFloor(&b, w);
    for (w.led()) |l| bakeLedge(&b, l);
    for (w.rmp()) |r| bakeRamp(&b, r);
    for (w.obs()) |o| {
        switch (o.Kind) {
            .rock => bakeBoulder(&b, o),
            .gravestone => bakeGravestone(&b, o),
            .tree => bakeTree(&b, o),
        }
    }
    for (w.dec()) |d| {
        switch (d.Kind) {
            .pebble => bakePebble(&b, d),
            .tuft => bakeTuft(&b, d),
            .shroom => bakeShroom(&b, d),
            .bone => bakeBone(&b, d),
            .bigshroom => bakeBigShroom(&b, d),
        }
    }
    const pos = b.pos.toOwnedSlice() catch @panic("oom");
    const nrm = b.nrm.toOwnedSlice() catch @panic("oom");
    const uv = b.uv.toOwnedSlice() catch @panic("oom");
    const col = b.col.toOwnedSlice() catch @panic("oom");

    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(pos.len / 3);
    mesh.triangleCount = @intCast(pos.len / 9);
    mesh.vertices = pos.ptr;
    mesh.normals = nrm.ptr;
    mesh.texcoords = uv.ptr;
    mesh.colors = col.ptr;
    rl.uploadMesh(&mesh, false);
    // GPU owns a copy; detach CPU pointers so unloadMesh only frees GPU buffers.
    mesh.vertices = null;
    mesh.normals = null;
    mesh.texcoords = null;
    mesh.colors = null;
    return .{ .mesh = mesh, .pos = pos, .nrm = nrm, .uv = uv, .col = col };
}

// SceneMesh owns the baked obstacle mesh and the two materials it draws with.
pub const SceneMesh = struct {
    mesh: rl.Mesh,
    sceneMat: rl.Material,
    depthMat: rl.Material,
    pos: []f32,
    nrm: []f32,
    uv: []f32,
    col: []u8,

    pub fn init(w: *const world.World, sceneShader: rl.Shader, depthShader: rl.Shader) SceneMesh {
        const baked = bakeMesh(w);
        var sceneMat = rl.loadMaterialDefault() catch @panic("loadMaterialDefault");
        sceneMat.shader = sceneShader;
        var depthMat = rl.loadMaterialDefault() catch @panic("loadMaterialDefault");
        depthMat.shader = depthShader;
        return .{ .mesh = baked.mesh, .sceneMat = sceneMat, .depthMat = depthMat, .pos = baked.pos, .nrm = baked.nrm, .uv = baked.uv, .col = baked.col };
    }

    // Swap in a new area's mesh, freeing the old but KEEPING the shared materials
    // so per-area transitions don't leak a default material each time.
    pub fn rebuild(self: *SceneMesh, w: *const world.World) void {
        self.freeMesh();
        const baked = bakeMesh(w);
        self.mesh = baked.mesh;
        self.pos = baked.pos;
        self.nrm = baked.nrm;
        self.uv = baked.uv;
        self.col = baked.col;
    }

    fn freeMesh(self: *SceneMesh) void {
        rl.unloadMesh(self.mesh); // GPU VAO/VBO only (CPU pointers were nulled)
        alloc.free(self.pos);
        alloc.free(self.nrm);
        alloc.free(self.uv);
        alloc.free(self.col);
    }

    pub fn deinit(self: *SceneMesh) void {
        self.freeMesh();
        // Materials only wrap torchlight's shaders (freed by the Torch); their tiny
        // default-map array is left to the OS at exit to avoid a shader double-free.
    }

    // Draw with backface culling off (winding-safe). Caller sets up the pass + shadow
    // map; identity transform since positions are already world-space.
    pub fn drawScene(self: *const SceneMesh) void {
        if (self.mesh.vertexCount == 0) return; // defensive; the floor always bakes
        rl.gl.rlDisableBackfaceCulling();
        rl.drawMesh(self.mesh, self.sceneMat, rl.math.matrixIdentity());
        rl.gl.rlEnableBackfaceCulling();
    }

    pub fn drawDepth(self: *const SceneMesh) void {
        if (self.mesh.vertexCount == 0) return;
        rl.gl.rlDisableBackfaceCulling();
        rl.drawMesh(self.mesh, self.depthMat, rl.math.matrixIdentity());
        rl.gl.rlEnableBackfaceCulling();
    }
};
