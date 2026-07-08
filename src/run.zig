const rl = @import("raylib");
const state = @import("state.zig");
const lighting = @import("lighting.zig");
const shadow = @import("shadow.zig");
const render = @import("render.zig");
const hud = @import("hud.zig");
const sim = @import("update.zig");

// run opens the window and drives the main loop until the user quits. (run.go)
pub fn run() void {
    rl.setConfigFlags(.{ .vsync_hint = true, .window_resizable = true });
    rl.initWindow(1280, 720, "Go Diablo");
    defer rl.closeWindow();
    rl.setExitKey(@enumFromInt(0)); // KEY_NULL — we handle Esc ourselves
    rl.setTargetFPS(60);

    var g = state.newGame(); // scene defaults to menu; the world behind it is area 0
    defer g.deinit();
    lighting.initLighting(&g);
    shadow.initShadows(&g);
    defer lighting.unloadLighting(&g);
    defer shadow.unloadShadows(&g);

    while (!rl.windowShouldClose()) {
        // Idle when minimized instead of running the full pipeline in the background.
        if (rl.isWindowMinimized()) {
            rl.waitTime(0.1);
            continue;
        }
        const dt = rl.getFrameTime();
        update(&g, dt);

        rl.beginDrawing();
        draw(&g);
        rl.endDrawing();

        // Throttle hard in the background so a left-open game can't hog the GPU.
        if (!rl.isWindowFocused()) rl.waitTime(0.05);
    }
}

fn update(g: *state.GameState, dt: f32) void {
    g.elapsed += dt; // advances in every scene (drives flicker/animation)
    // Toggle GPU lighting vs. CPU-shaded fallback (A/B testing).
    if (g.lightLoaded and rl.isKeyPressed(.l)) g.lightingOn = !g.lightingOn;
    if (g.shadowReady and rl.isKeyPressed(.k)) g.shadowsOn = !g.shadowsOn;
    switch (g.scene) {
        .menu => {
            if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.space)) g.startRun();
            // Let the menu's backdrop drift the camera a touch.
            g.rig.follow(g.player.Pos, dt);
        },
        .playing => {
            if (rl.isKeyPressed(.escape)) g.scene = .menu;
            sim.updatePlaying(g, dt);
        },
        .dead => {
            if (rl.isKeyPressed(.r)) g.startRun();
        },
        .victory => {
            if (rl.isKeyPressed(.enter)) g.startRun();
        },
    }
}

fn draw(g: *state.GameState) void {
    switch (g.scene) {
        .menu => {
            render.drawWorld3D(g);
            hud.drawVignette(g);
            hud.drawMenu(g);
        },
        .playing => {
            render.drawWorld3D(g);
            hud.drawVignette(g);
            hud.drawHUD(g);
            if (g.paused) hud.drawPauseOverlay(g);
        },
        .dead => {
            render.drawWorld3D(g);
            hud.drawVignette(g);
            hud.drawHUD(g);
            hud.drawDeath(g);
        },
        .victory => {
            render.drawWorld3D(g);
            hud.drawVignette(g);
            hud.drawVictory(g);
        },
    }
}
