const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const tl = @import("torchlight.zig");
const world = @import("world.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const lerpColor = mathx.lerpColor;

// The game, rebuilt on the demo's exact lighting (torchlight.zig, copied verbatim
// from the frozen demo2.zig). The lighting is NOT to be altered here.
//
// Layered back in one testable step at a time on top of the verified CHUNK 1 base
// (ground + WASD player + torch + follow camera):
//   LAYER 1: the real arena floor + boundary walls, sized/colored to area 0.
//   LAYER 2 (this step): boulders — the SHORT casters (top ~2.7u, well under the
//     torch at 6u), so their cast shadows stay short and sane. Drawn in plain tint;
//     torchlight lights + shadows them. No collision yet (player passes through).
//   Next layers: gravestones → trees → obstacle collision → spawn point.

// Follow camera: the demo's iso angle (offset 0,26,24 from the look-at point), but
// tracking the player instead of the origin. Feeds viewPos to the shader exactly as
// the demo's fixed camera did — a view change, not a lighting one.
fn followCamera(player: rl.Vector3) rl.Camera3D {
    return .{
        .position = v3(player.x, 26, player.z + 24),
        .target = v3(player.x, 1, player.z),
        .up = v3(0, 1, 0),
        .fovy = 50,
        .projection = .perspective,
    };
}

fn drawPlayer(pos: rl.Vector3) void {
    rl.drawCubeV(v3(pos.x, 0.75, pos.z), v3(1, 1.5, 1), rgba(60, 220, 120, 255));
}

// Boulder: two overlapping spheres, ported from render.zig sans the old lighting
// helpers (plain tint — torchlight does the shading and casts real shadows).
fn drawBoulder(o: world.Obstacle) void {
    rl.drawSphere(v3(o.Pos.x, o.Height * 0.35, o.Pos.z), o.Radius, o.Tint);
    rl.drawSphere(v3(o.Pos.x + o.Radius * 0.4, o.Height * 0.22, o.Pos.z + o.Radius * 0.3), o.Radius * 0.6, lerpColor(o.Tint, rl.Color.black, 0.15));
}

// Draw only the .rock obstacles for now; other kinds arrive in later layers.
// raylib's immediate-mode render batch auto-flushes when it fills; that flush drops
// the shadow-map texture we bound on slot 10, after which the scene shader samples
// garbage and the whole ground reads as shadowed (the torch pool collapses). So we
// flush at controlled boundaries — while slot 10 is still bound — and rebind it for
// the next chunk. Each chunk between calls must stay under the batch limit (a single
// obstacle easily does). This is a batching-robustness fix; it does NOT touch the
// lighting math in torchlight.zig.
fn keepShadowBound(torch: *tl.Torch) void {
    rl.gl.rlDrawRenderBatchActive(); // flush the queued chunk now, slot 10 still bound
    rl.gl.rlActiveTextureSlot(10);
    rl.gl.rlEnableTexture(@intCast(torch.shadowMap.depth.id));
    rl.gl.rlActiveTextureSlot(0);
}

// Depth-pass draw (no shadow sampling here, so no rebind needed).
fn drawBoulders(w: *const world.World) void {
    for (w.obs()) |o| {
        if (o.Kind == .rock) drawBoulder(o);
    }
}

// Main-pass draw: rebind the shadow map between boulders so a mid-scene batch
// overflow can never orphan it.
fn drawBouldersLit(torch: *tl.Torch, w: *const world.World) void {
    for (w.obs()) |o| {
        if (o.Kind != .rock) continue;
        keepShadowBound(torch);
        drawBoulder(o);
    }
}

fn drawWalls(w: *const world.World) void {
    const h = w.Half;
    const wallH = 4.0;
    const t = 1.2;
    const col = w.Accent;
    const segs = [_]rl.Vector3{
        v3(0, wallH / 2, -h), v3(0, wallH / 2, h),
        v3(-h, wallH / 2, 0), v3(h, wallH / 2, 0),
    };
    const sizes = [_]rl.Vector3{
        v3(h * 2 + t, wallH, t), v3(h * 2 + t, wallH, t),
        v3(t, wallH, h * 2 + t), v3(t, wallH, h * 2 + t),
    };
    for (segs, sizes) |seg, size| rl.drawCubeV(seg, size, col);
}

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var torch = tl.Torch.init() catch return;
    defer torch.deinit();

    var rng = mathx.Rng.init(if (shot) 1234 else mathx.timeSeed());
    const w = world.buildWorld(world.areas[0], &rng, false);

    var player = v3(0, 0, 0); // centered for now; real spawn point is a later layer
    var torchHeight: f32 = 6.0; // demo default (Q/E to tune)
    var torchRadius: f32 = 12.0; // demo default (wheel to tune)

    const sweep = [_]rl.Vector3{ v3(0, 0, 2), v3(-7, 0, -4) };
    if (shot) player = sweep[0];
    var frame: i32 = 0;
    var shotIdx: usize = 0;

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const speed = 10.0 * dt;
        if (rl.isKeyDown(.w)) player.z -= speed;
        if (rl.isKeyDown(.s)) player.z += speed;
        if (rl.isKeyDown(.a)) player.x -= speed;
        if (rl.isKeyDown(.d)) player.x += speed;
        const bound = w.Half - 2.0;
        player.x = mathx.clampF(player.x, -bound, bound);
        player.z = mathx.clampF(player.z, -bound, bound);
        if (rl.isKeyDown(.q)) torchHeight = mathx.clampF(torchHeight - 12.0 * dt, 5, 30);
        if (rl.isKeyDown(.e)) torchHeight = mathx.clampF(torchHeight + 12.0 * dt, 5, 30);
        torchRadius = mathx.clampF(torchRadius + rl.getMouseWheelMove() * 1.5, 4, 28);

        const cam = followCamera(player);
        const lp = tl.LightParams{ .pos = v3(player.x, torchHeight, player.z), .radius = torchRadius };

        // --- depth pass (player + boulders cast) ---
        torch.beginShadowPass(lp);
        drawBoulders(&w);
        drawPlayer(player);
        torch.endShadowPass();

        // --- main pass ---
        rl.beginDrawing();
        rl.clearBackground(rgba(16, 16, 22, 255));
        torch.applyUniforms(cam, lp);
        rl.beginMode3D(cam);
        torch.beginScene();
        // torchlight.beginScene binds the shadow map on texture slot 10 and leaves
        // that slot active. Reset the active slot to 0 (as the old render.zig did) so
        // that when the render batch overflows mid-scene — which it does once there's
        // real scenery — raylib's immediate-mode texture0 binds go to slot 0 and don't
        // clobber the shadow map on slot 10. Without this, a busy scene reads as fully
        // shadowed and the torch pool collapses. Does NOT alter the lighting itself.
        rl.gl.rlActiveTextureSlot(0);
        rl.drawPlane(v3(0, 0, 0), rl.Vector2.init(w.Half * 2, w.Half * 2), w.Ground);
        drawWalls(&w);
        drawBouldersLit(&torch, &w);
        keepShadowBound(&torch);
        drawPlayer(player);
        torch.endScene();
        rl.drawSphere(lp.pos, 0.5, rgba(255, 240, 180, 255)); // the torch
        rl.endMode3D();

        var namebuf: [96]u8 = undefined;
        const areaName = std.fmt.bufPrintZ(&namebuf, "{s}", .{w.Name}) catch "";
        rl.drawText(areaName, 20, 20, 20, rl.Color.ray_white);
        rl.drawText("WASD move    Q/E torch height    wheel: light radius", 20, 46, 20, rl.Color.ray_white);
        var posbuf: [64]u8 = undefined;
        const posTxt = std.fmt.bufPrintZ(&posbuf, "pos  x={d:.1}  z={d:.1}", .{ player.x, player.z }) catch "";
        rl.drawText(posTxt, 20, 74, 20, rl.Color.ray_white);
        rl.drawFPS(20, 100);
        rl.endDrawing();

        if (shot) {
            frame += 1;
            if (frame >= 3) {
                frame = 0;
                std.fs.cwd().makePath("shots") catch {};
                var buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&buf, "shots/shot_game_{d}.png", .{shotIdx + 1}) catch break;
                rl.takeScreenshot(name);
                shotIdx += 1;
                if (shotIdx >= sweep.len) break;
                player = sweep[shotIdx];
            }
        }
    }
}
