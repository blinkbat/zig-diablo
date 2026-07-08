const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

// BASICS: a point light that MOVES WITH YOU (WASD), casting shadows from blocks
// onto a plane. Fixed camera so you can watch the light + shadows move across a
// static scene. This isolates the moving-light case. `--demo2` runs it live;
// `--demo2shot` renders one frame to shot_demo2.png.

const SHADOWMAP_RESOLUTION = 6144; // higher res so shadows stay crisp over the footprint
// The torch sits LOW so cast shadows are long and dramatic. Instead of a fixed cone
// FOV, we compute it each frame to just cover the light radius (x this margin): the
// shadow cone always contains the visible pool, so shadows never clip where you can
// see them -- any clipping falls out in the darkness beyond the radius, unseen. This
// is what lets the torch drop low (long shadows) without the earlier edge-clipping.
const LIGHT_HEIGHT = 6.0;
const SHADOW_COVER_MARGIN = 1.3;

const depthVS =
    \\#version 330
    \\in vec3 vertexPosition;
    \\uniform mat4 mvp;
    \\void main() { gl_Position = mvp*vec4(vertexPosition, 1.0); }
;
const depthFS =
    \\#version 330
    \\out vec4 c;
    \\void main() { c = vec4(1.0); }
;

const sceneVS =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec2 vertexTexCoord;
    \\in vec3 vertexNormal;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\uniform mat4 matModel;
    \\out vec3 fragPosition;
    \\out vec2 fragTexCoord;
    \\out vec4 fragColor;
    \\out vec3 fragNormal;
    \\void main() {
    \\    fragPosition = vec3(matModel*vec4(vertexPosition, 1.0));
    \\    fragTexCoord = vertexTexCoord;
    \\    fragColor = vertexColor;
    \\    fragNormal = normalize(vertexNormal);
    \\    gl_Position = mvp*vec4(vertexPosition, 1.0);
    \\}
;
const sceneFS =
    \\#version 330
    \\in vec3 fragPosition;
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\in vec3 fragNormal;
    \\uniform sampler2D texture0;
    \\uniform vec3 lightPos;
    \\uniform vec4 lightColor;
    \\uniform vec4 ambient;
    \\uniform vec3 viewPos;
    \\uniform mat4 lightVP;
    \\uniform sampler2D shadowMap;
    \\uniform int shadowMapResolution;
    \\uniform float lightRadius;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 texelColor = texture(texture0, fragTexCoord);
    \\    vec3 normal = normalize(fragNormal);
    \\    vec3 l = normalize(lightPos - fragPosition);
    \\    float NdotL = max(dot(normal, l), 0.0);
    \\    vec3 lightDot = lightColor.rgb*NdotL;
    \\    vec3 viewD = normalize(viewPos - fragPosition);
    \\    vec3 specular = vec3(0.0);
    \\    if (NdotL > 0.0) specular = vec3(pow(max(0.0, dot(viewD, reflect(-l, normal))), 16.0));
    \\    finalColor = (texelColor*((fragColor + vec4(specular, 1.0))*vec4(lightDot, 1.0)));
    \\    vec4 p = lightVP*vec4(fragPosition, 1.0);
    \\    p.xyz /= p.w;
    \\    p.xyz = p.xyz*0.5 + 0.5;
    \\    if (p.z <= 1.0 && p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
    \\        float bias = max(0.0025*(1.0 - dot(normal, l)), 0.0007);
    \\        int sc = 0;
    \\        float texel = 1.0/float(shadowMapResolution);
    \\        for (int x = -1; x <= 1; x++)
    \\            for (int y = -1; y <= 1; y++)
    \\                if (p.z - bias > texture(shadowMap, p.xy + vec2(x, y)*texel).r) sc++;
    \\        finalColor = mix(finalColor, vec4(0, 0, 0, 1), float(sc)/9.0);
    \\    }
    \\    finalColor += texelColor*(ambient/10.0)*fragColor;
    \\    // LIGHT RADIUS: your torch only reaches so far. Past it, darkness -- unseen.
    \\    // Measured as horizontal distance from the torch axis (= you) on the ground,
    \\    // so it reads as a disc of light around you. Fades both the lit color and the
    \\    // ambient to black, so beyond the radius the world genuinely disappears.
    \\    float lightDist = length(fragPosition.xz - lightPos.xz);
    \\    float vis = 1.0 - smoothstep(lightRadius*0.65, lightRadius, lightDist);
    \\    finalColor.rgb *= vis;
    \\    finalColor = pow(finalColor, vec4(1.0/2.2));
    \\}
;

fn loadShadowmap(res: i32) rl.RenderTexture2D {
    const fbo = rl.gl.rlLoadFramebuffer();
    const depthTex = rl.gl.rlLoadTextureDepth(res, res, false);
    rl.gl.rlFramebufferAttach(fbo, depthTex, 100, 100, 0);
    const fmt = rl.PixelFormat.uncompressed_grayscale;
    return .{
        .id = @intCast(fbo),
        .texture = .{ .id = 0, .width = res, .height = res, .mipmaps = 1, .format = fmt },
        .depth = .{ .id = @intCast(depthTex), .width = res, .height = res, .mipmaps = 1, .format = fmt },
    };
}

const Block = struct { pos: rl.Vector3, size: rl.Vector3, color: rl.Color };
const blocks = [_]Block{
    .{ .pos = v3(-6, 1.0, -4), .size = v3(2, 2, 2), .color = rgba(200, 90, 90, 255) },
    .{ .pos = v3(5, 1.5, -6), .size = v3(2, 3, 2), .color = rgba(90, 160, 210, 255) },
    .{ .pos = v3(-4, 1.0, 5), .size = v3(2, 2, 2), .color = rgba(100, 200, 120, 255) },
    .{ .pos = v3(7, 1.0, 4), .size = v3(2.5, 2, 2.5), .color = rgba(210, 190, 90, 255) },
    .{ .pos = v3(0, 2.0, -9), .size = v3(2, 4, 2), .color = rgba(200, 140, 220, 255) },
    .{ .pos = v3(-9, 1.0, 1), .size = v3(2, 2, 2), .color = rgba(180, 180, 190, 255) },
};

fn drawCasters(player: rl.Vector3) void {
    for (blocks) |b| rl.drawCubeV(b.pos, b.size, b.color);
    rl.drawCubeV(v3(player.x, 0.75, player.z), v3(1, 1.5, 1), rgba(60, 220, 120, 255)); // you
}

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1000, 720, "BASICS: moving point light + cast shadows (WASD)");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const shadowMap = loadShadowmap(SHADOWMAP_RESOLUTION);
    const depthShader = rl.loadShaderFromMemory(depthVS, depthFS) catch return;
    defer rl.unloadShader(depthShader);
    const scene = rl.loadShaderFromMemory(sceneVS, sceneFS) catch return;
    defer rl.unloadShader(scene);

    const loc_lightPos = rl.getShaderLocation(scene, "lightPos");
    const loc_viewPos = rl.getShaderLocation(scene, "viewPos");
    const loc_lightVP = rl.getShaderLocation(scene, "lightVP");
    const loc_lightRadius = rl.getShaderLocation(scene, "lightRadius");
    const lc = [4]f32{ 1.0, 0.95, 0.85, 1.0 };
    rl.setShaderValue(scene, rl.getShaderLocation(scene, "lightColor"), &lc, .vec4);
    const amb = [4]f32{ 0.6, 0.6, 0.7, 1.0 };
    rl.setShaderValue(scene, rl.getShaderLocation(scene, "ambient"), &amb, .vec4);
    const res: i32 = SHADOWMAP_RESOLUTION;
    rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMapResolution"), &res, .int);
    const slot: i32 = 10;
    rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMap"), &slot, .int);

    // Fixed iso camera — the scene stays put so you can see the light move.
    const cam = rl.Camera3D{
        .position = v3(0, 26, 24),
        .target = v3(0, 1, 0),
        .up = v3(0, 1, 0),
        .fovy = 50,
        .projection = .perspective,
    };

    // Shot mode sweeps the light through these positions to prove shadows stay
    // correct while it moves (the whole point). Live mode starts centered.
    const sweep = [_]rl.Vector3{ v3(-8, 0, -6), v3(0, 0, 0), v3(6, 0, 5), v3(11, 0, -8) };
    var player = if (shot) sweep[0] else v3(0, 0, 0);
    var lightHeight: f32 = LIGHT_HEIGHT;
    var lightRadius: f32 = 12.0; // how far your torch reaches before darkness
    var frame: i32 = 0;
    var shotIdx: usize = 0;

    while (!rl.windowShouldClose()) {
        // WASD moves you — and the light moves with you.
        const speed = 10.0 * rl.getFrameTime();
        if (rl.isKeyDown(.w)) player.z -= speed;
        if (rl.isKeyDown(.s)) player.z += speed;
        if (rl.isKeyDown(.a)) player.x -= speed;
        if (rl.isKeyDown(.d)) player.x += speed;
        player.x = mathx.clampF(player.x, -13, 13);
        player.z = mathx.clampF(player.z, -13, 13);
        // Q/E lower/raise the torch live: lower = longer, more dramatic shadows that
        // clip sooner; higher = shorter shadows over a wider disc. Feel out the trade.
        if (rl.isKeyDown(.q)) lightHeight = mathx.clampF(lightHeight - 12.0 * rl.getFrameTime(), 5, 30);
        if (rl.isKeyDown(.e)) lightHeight = mathx.clampF(lightHeight + 12.0 * rl.getFrameTime(), 5, 30);
        // Mouse wheel grows/shrinks your light radius -- the core resource.
        lightRadius = mathx.clampF(lightRadius + rl.getMouseWheelMove() * 1.5, 4, 28);

        const lightPos = v3(player.x, lightHeight, player.z); // torch: directly above/on you, moves with you

        // Size the shadow cone to just cover the light radius (x margin): coverage on
        // the ground = height*tan(fovy/2), so fovy = 2*atan(coverTarget/height). A low
        // torch shrinks coverage, so we WIDEN the cone to compensate -- the cone always
        // contains the visible pool, so long shadows never clip where you can see them.
        const coverTarget = lightRadius * SHADOW_COVER_MARGIN;
        const shadowFovy = mathx.clampF(2.0 * std.math.atan(coverTarget / lightHeight) * (180.0 / std.math.pi), 30.0, 150.0);

        // --- depth pass from the light (looking straight down; `up` must not be
        // parallel to the view direction or MatrixLookAt goes degenerate/NaN) ---
        const lightCam = rl.Camera3D{
            .position = lightPos,
            .target = v3(player.x, 0, player.z),
            .up = v3(0, 0, -1),
            .fovy = shadowFovy,
            .projection = .perspective,
        };
        const near = rl.gl.rlGetCullDistanceNear();
        const far = rl.gl.rlGetCullDistanceFar();
        rl.gl.rlSetClipPlanes(1.0, 45.0);
        rl.beginTextureMode(shadowMap);
        rl.clearBackground(rl.Color.white);
        rl.beginMode3D(lightCam);
        const lightVP = rl.math.matrixMultiply(rl.gl.rlGetMatrixModelview(), rl.gl.rlGetMatrixProjection());
        rl.beginShaderMode(depthShader);
        drawCasters(player);
        rl.endShaderMode();
        rl.endMode3D();
        rl.endTextureMode();
        rl.gl.rlSetClipPlanes(near, far);

        // --- main pass ---
        rl.beginDrawing();
        rl.clearBackground(rgba(16, 16, 22, 255));
        const lp = [3]f32{ lightPos.x, lightPos.y, lightPos.z };
        rl.setShaderValue(scene, loc_lightPos, &lp, .vec3);
        const vp = [3]f32{ cam.position.x, cam.position.y, cam.position.z };
        rl.setShaderValue(scene, loc_viewPos, &vp, .vec3);
        rl.setShaderValue(scene, loc_lightRadius, &lightRadius, .float);
        rl.setShaderValueMatrix(scene, loc_lightVP, lightVP);
        rl.beginMode3D(cam);
        rl.beginShaderMode(scene);
        rl.gl.rlActiveTextureSlot(10);
        rl.gl.rlEnableTexture(@intCast(shadowMap.depth.id));
        rl.drawPlane(v3(0, 0, 0), rl.Vector2{ .x = 32, .y = 32 }, rgba(120, 120, 130, 255));
        drawCasters(player);
        rl.endShaderMode();
        rl.drawSphere(lightPos, 0.5, rgba(255, 240, 180, 255)); // the light
        rl.endMode3D();
        rl.drawText("WASD move    Q/E torch height    mouse wheel: light radius", 20, 20, 20, rl.Color.ray_white);
        var hudbuf: [96]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&hudbuf, "torch height {d:.1}    light radius {d:.1}", .{ lightHeight, lightRadius }) catch unreachable;
        rl.drawText(txt, 20, 48, 20, rl.Color.ray_white);
        rl.drawFPS(20, 76);
        rl.endDrawing();

        if (shot) {
            frame += 1;
            if (frame >= 3) {
                frame = 0;
                var buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&buf, "shot_demo2_{d}.png", .{shotIdx + 1}) catch break;
                rl.takeScreenshot(name);
                shotIdx += 1;
                if (shotIdx >= sweep.len) break;
                player = sweep[shotIdx];
            }
        }
    }
}
