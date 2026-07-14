const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const world = @import("world.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;
const sinf = mathx.sinf;
const cosf = mathx.cosf;

// SCENE MESH — the arena's static obstacles (boulders, gravestones, trees) baked
// into ONE GPU mesh at area load, instead of regenerating hundreds of thousands of
// vertices on the CPU every frame (shadow + main pass) — that regen was the FPS
// bottleneck. Once uploaded, each pass is a single GPU call.
//
// Mesh carries per-vertex tints + outward normals, exactly what torchlight's scene
// shader reads (fragColor + fragNormal). Drawn backface-culling-off so a winding
// mistake can't hide a face.

// c_allocator is malloc, matching raylib's libc free() in UnloadMesh, so ownership
// transfers cleanly after uploadMesh.
const alloc = std.heap.c_allocator;

const Builder = struct {
    pos: std.ArrayList(f32),
    nrm: std.ArrayList(f32),
    uv: std.ArrayList(f32),
    col: std.ArrayList(u8),

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
        self.uv.appendSlice(&.{ 0, 0 }) catch @panic("oom");
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
    b.addSphere(v3(o.Pos.x, gy + o.Height * 0.35, o.Pos.z), o.Radius, 8, 8, o.Tint);
    b.addSphere(v3(o.Pos.x + o.Radius * 0.4, gy + o.Height * 0.22, o.Pos.z + o.Radius * 0.3), o.Radius * 0.6, 8, 8, lerpColor(o.Tint, rl.Color.black, 0.15));
    // A shed chip against the parent stone: boulders come in families.
    b.addSphere(v3(o.Pos.x - o.Radius * 0.85, gy + o.Radius * 0.16, o.Pos.z - o.Radius * 0.45), o.Radius * 0.28, 6, 6, lerpColor(o.Tint, rl.Color.white, 0.08));
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
    const lean = v3(0.12, 0, 0.05);
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
    var prev = v3(x, gy, z);
    var i: i32 = 1;
    while (i <= segs_n) : (i += 1) {
        const f: f32 = @as(f32, @floatFromInt(i)) / segs_n;
        const top = v3(x + lean.x * o.Height * f * f, gy + o.Height * 0.62 * f, z + lean.z * o.Height * f * f);
        const r0 = trunk_r * (1 - 0.6 * @as(f32, @floatFromInt(i - 1)) / segs_n);
        const r1 = trunk_r * (1 - 0.6 * f);
        b.addCylinder(prev, top, r0, r1, 8, bark);
        prev = top;
    }
    const crown = prev;

    const branchCol = lerpColor(bark, rl.Color.black, 0.2);
    var j: i32 = 0;
    while (j < 5) : (j += 1) {
        const jf: f32 = @floatFromInt(j);
        const ang = jf * (2.0 * std.math.pi / 5.0) + 0.5;
        const out = 0.35 + 0.2 * sinf(o.Height + jf);
        const tip = v3(crown.x + cosf(ang) * out, crown.y + 0.35 + 0.25 * sinf(jf), crown.z + sinf(ang) * out);
        b.addCylinder(crown, tip, 0.16, 0.05, 5, branchCol);
    }

    // Deep forest green. The scene shader's output gamma (pow 1/2.2) lifts dark
    // albedos hard, so the canopy starts near-black to read as rich green, not sage.
    const canopy = lerpColor(o.Tint, rgba(12, 24, 14, 255), 0.9);
    const cr = o.Radius * 1.15;
    b.addSphere(v3(crown.x, crown.y + 0.5, crown.z), cr, 8, 8, canopy);
    var k: i32 = 0;
    while (k < 6) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ang = kf * (std.math.pi / 3.0) + o.Height;
        const cp = v3(crown.x + cosf(ang) * cr * 0.7, crown.y + 0.35 + 0.18 * sinf(kf + o.Height), crown.z + sinf(ang) * cr * 0.7);
        b.addSphere(cp, cr * 0.72, 8, 8, canopy);
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
        const tipCol = lerpColor(d.Tint, rgba(172, 195, 100, 255), 0.5 + 0.12 * @mod(iff, 2.0));
        b.addCylinder(root, mid, 0.055 * (0.8 + d.Size), 0.03, 3, rootCol);
        b.addCylinder(mid, tip, 0.03, 0.0, 3, tipCol);
    }
}

fn bakeShroom(b: *Builder, d: world.Decor) void {
    const stemH = d.Size * 1.1;
    b.addCylinder(v3(d.Pos.x, d.Pos.y, d.Pos.z), v3(d.Pos.x, d.Pos.y + stemH, d.Pos.z), d.Size * 0.22, d.Size * 0.16, 5, rgba(216, 206, 186, 255));
    b.addSphere(v3(d.Pos.x, d.Pos.y + stemH, d.Pos.z), d.Size * 0.55, 6, 6, d.Tint);
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

// ---- Terrain features (ledges + ramps; see world.zig TERRAIN) ----

fn bakeLedge(b: *Builder, w: *const world.World, l: world.Ledge) void {
    const cx = (l.minX + l.maxX) / 2;
    const cz = (l.minZ + l.maxZ) / 2;
    const sx = l.maxX - l.minX;
    const sz = l.maxZ - l.minZ;
    // Arena-wall masonry profile: body, paler overhanging capstone (the walkable
    // pavement), darker foot plinth.
    const body = w.Accent;
    // Barely paler than the floor: the walkway must read as GROUND you fight on
    // (output gamma blows bright albedos out under the torch).
    const cap = lerpColor(w.Ground, rgba(126, 120, 110, 255), 0.22);
    const plinth = lerpColor(body, rl.Color.black, 0.35);
    b.addCube(v3(cx, l.h / 2, cz), v3(sx, l.h, sz), body);
    b.addCube(v3(cx, l.h + 0.07, cz), v3(sx + 0.3, 0.14, sz + 0.3), cap);
    b.addCube(v3(cx, 0.15, cz), v3(sx + 0.2, 0.3, sz + 0.2), plinth);
}

fn bakeRamp(b: *Builder, w: *const world.World, r: world.Ramp) void {
    const k = r.planeCoeffs(); // gradient for the top-face normal below
    const worn = lerpColor(w.Accent, rgba(150, 145, 132, 255), 0.3);
    const side = lerpColor(w.Accent, rl.Color.black, 0.2);
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
    // Top surface: one planar quad, normal = plane gradient.
    b.quad(top[0], top[3], top[2], top[1], norm(v3(-k[0], 1, -k[1])), worn);
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
    for (w.led()) |l| bakeLedge(&b, w, l);
    for (w.rmp()) |r| bakeRamp(&b, w, r);
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
        if (self.mesh.vertexCount == 0) return; // an obstacle-less area bakes nothing
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
