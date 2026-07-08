const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const tl = @import("torchlight.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

// The game, rebuilt on the demo's exact lighting (torchlight.zig, copied verbatim
// from the frozen demo2.zig). The lighting is NOT to be altered here.
//
// CHUNK 1 — the playable foundation:
//   * a ground plane
//   * a player you move with WASD
//   * a torch that rides on the player (the demo's point light + shadows + radius)
//   * placeholder blocks so cast shadows are visible
//   * a follow camera (the historically-tricky "moving torch under a moving camera")
// Real world / obstacles / monsters / HUD arrive in later chunks.

const GROUND_SIZE = 200.0;

// Placeholder casters until real obstacles arrive in chunk 2.
const Block = struct { pos: rl.Vector3, size: rl.Vector3, color: rl.Color };
const blocks = [_]Block{
    .{ .pos = v3(-6, 1.0, -4), .size = v3(2, 2, 2), .color = rgba(200, 90, 90, 255) },
    .{ .pos = v3(5, 1.5, -6), .size = v3(2, 3, 2), .color = rgba(90, 160, 210, 255) },
    .{ .pos = v3(-4, 1.0, 5), .size = v3(2, 2, 2), .color = rgba(100, 200, 120, 255) },
    .{ .pos = v3(7, 1.0, 4), .size = v3(2.5, 2, 2.5), .color = rgba(210, 190, 90, 255) },
    .{ .pos = v3(0, 2.0, -9), .size = v3(2, 4, 2), .color = rgba(200, 140, 220, 255) },
    .{ .pos = v3(-9, 1.0, 1), .size = v3(2, 2, 2), .color = rgba(180, 180, 190, 255) },
    .{ .pos = v3(12, 1.0, -2), .size = v3(2, 2, 2), .color = rgba(170, 120, 90, 255) },
    .{ .pos = v3(-13, 1.5, -8), .size = v3(2, 3, 2), .color = rgba(120, 150, 170, 255) },
};

fn drawCasters(player: rl.Vector3) void {
    for (blocks) |b| rl.drawCubeV(b.pos, b.size, b.color);
    rl.drawCubeV(v3(player.x, 0.75, player.z), v3(1, 1.5, 1), rgba(60, 220, 120, 255)); // player
}

// Follow camera: the demo's iso angle (offset 0,25,24 from the look-at point), but
// tracking the player instead of the origin. The camera feeds viewPos to the shader
// exactly as the demo's fixed camera did — this is a view change, not a lighting one.
fn followCamera(player: rl.Vector3) rl.Camera3D {
    return .{
        .position = v3(player.x, 26, player.z + 24),
        .target = v3(player.x, 1, player.z),
        .up = v3(0, 1, 0),
        .fovy = 50,
        .projection = .perspective,
    };
}

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1280, 800, "zig-diablo");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var torch = tl.Torch.init() catch return;
    defer torch.deinit();

    var player = v3(0, 0, 0);
    var torchHeight: f32 = 6.0; // demo default (Q/E to tune)
    var torchRadius: f32 = 12.0; // demo default (wheel to tune)

    // Shot mode steps the player through a couple of spots to confirm the follow
    // camera + moving torch stay clean.
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
        const bound = GROUND_SIZE / 2.0 - 4.0;
        player.x = mathx.clampF(player.x, -bound, bound);
        player.z = mathx.clampF(player.z, -bound, bound);
        if (rl.isKeyDown(.q)) torchHeight = mathx.clampF(torchHeight - 12.0 * dt, 5, 30);
        if (rl.isKeyDown(.e)) torchHeight = mathx.clampF(torchHeight + 12.0 * dt, 5, 30);
        torchRadius = mathx.clampF(torchRadius + rl.getMouseWheelMove() * 1.5, 4, 28);

        const cam = followCamera(player);
        const lp = tl.LightParams{ .pos = v3(player.x, torchHeight, player.z), .radius = torchRadius };

        // --- depth pass ---
        torch.beginShadowPass(lp);
        drawCasters(player);
        torch.endShadowPass();

        // --- main pass ---
        rl.beginDrawing();
        rl.clearBackground(rgba(16, 16, 22, 255));
        torch.applyUniforms(cam, lp);
        rl.beginMode3D(cam);
        torch.beginScene();
        rl.drawPlane(v3(0, 0, 0), rl.Vector2{ .x = GROUND_SIZE, .y = GROUND_SIZE }, rgba(120, 120, 130, 255));
        drawCasters(player);
        torch.endScene();
        rl.drawSphere(lp.pos, 0.5, rgba(255, 240, 180, 255)); // the torch
        rl.endMode3D();

        rl.drawText("WASD move    Q/E torch height    wheel: light radius", 20, 20, 20, rl.Color.ray_white);
        rl.drawFPS(20, 48);
        rl.endDrawing();

        if (shot) {
            frame += 1;
            if (frame >= 3) {
                frame = 0;
                var buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&buf, "shot_game_{d}.png", .{shotIdx + 1}) catch break;
                rl.takeScreenshot(name);
                shotIdx += 1;
                if (shotIdx >= sweep.len) break;
                player = sweep[shotIdx];
            }
        }
    }
}
