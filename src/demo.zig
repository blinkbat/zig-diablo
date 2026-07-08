const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

// Point-light shadow demo — a faithful port of raylib's official shadowmap example
// (examples/shaders/shaders_shadowmap, zlib license), adapted from a DIRECTIONAL
// light to a POINT light exactly as the raylib docs prescribe: the light camera is
// perspective (FOV = the light's FOV), and the fragment shader uses
// l = normalize(lightPos - fragPosition) instead of -lightDir.
//
// `--demo` runs it live (light orbits); `--demoshot` renders one frame to a PNG.

const SHADOWMAP_RESOLUTION = 2048;

// Vertex shader: raylib shadowmap.vs, verbatim except fragNormal — the official
// uses matNormal (set by raylib's model/material path). We draw immediate-mode
// shapes (only translated, never rotated), so the raw vertexNormal IS the world
// normal; this avoids depending on matNormal being bound for DrawCube.
const shadowVS =
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

// Fragment shader: raylib shadowmap.fs, verbatim except the two point-light lines
// (lightPos instead of lightDir) and a larger bias for the perspective light.
const shadowFS =
    \\#version 330
    \\in vec3 fragPosition;
    \\in vec2 fragTexCoord;
    \\in vec3 fragNormal;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 lightPos;
    \\uniform vec4 lightColor;
    \\uniform vec4 ambient;
    \\uniform vec3 viewPos;
    \\uniform mat4 lightVP;
    \\uniform sampler2D shadowMap;
    \\uniform int shadowMapResolution;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 texelColor = texture(texture0, fragTexCoord);
    \\    vec3 lightDot = vec3(0.0);
    \\    vec3 normal = normalize(fragNormal);
    \\    vec3 viewD = normalize(viewPos - fragPosition);
    \\    vec3 specular = vec3(0.0);
    \\    vec3 l = normalize(lightPos - fragPosition);
    \\    float NdotL = max(dot(normal, l), 0.0);
    \\    lightDot += lightColor.rgb*NdotL;
    \\    float specCo = 0.0;
    \\    if (NdotL > 0.0) specCo = pow(max(0.0, dot(viewD, reflect(-(l), normal))), 16.0);
    \\    specular += specCo;
    \\    finalColor = (texelColor*((colDiffuse + vec4(specular, 1.0))*vec4(lightDot, 1.0)));
    \\    vec4 fragPosLightSpace = lightVP*vec4(fragPosition, 1);
    \\    fragPosLightSpace.xyz /= fragPosLightSpace.w;
    \\    fragPosLightSpace.xyz = (fragPosLightSpace.xyz + 1.0)/2.0;
    \\    vec2 sampleCoords = fragPosLightSpace.xy;
    \\    float curDepth = fragPosLightSpace.z;
    \\    float bias = max(0.0025*(1.0 - dot(normal, l)), 0.0007);
    \\    int shadowCounter = 0;
    \\    const int numSamples = 9;
    \\    vec2 texelSize = vec2(1.0/float(shadowMapResolution));
    \\    for (int x = -1; x <= 1; x++) {
    \\        for (int y = -1; y <= 1; y++) {
    \\            float sampleDepth = texture(shadowMap, sampleCoords + texelSize*vec2(x, y)).r;
    \\            if (curDepth - bias > sampleDepth) shadowCounter++;
    \\        }
    \\    }
    \\    finalColor = mix(finalColor, vec4(0, 0, 0, 1), float(shadowCounter)/float(numSamples));
    \\    finalColor += texelColor*(ambient/10.0)*colDiffuse;
    \\    finalColor = pow(finalColor, vec4(1.0/2.2));
    \\}
;

// Equivalent of raylib's LoadShadowmapRenderTexture: a depth-only framebuffer.
fn loadShadowmap(width: i32, height: i32) rl.RenderTexture2D {
    const fbo = rl.gl.rlLoadFramebuffer();
    const depthTex = rl.gl.rlLoadTextureDepth(width, height, false);
    rl.gl.rlFramebufferAttach(fbo, depthTex, 100, 100, 0); // RL_ATTACHMENT_DEPTH, RL_ATTACHMENT_TEXTURE2D
    const fmt = rl.PixelFormat.uncompressed_grayscale;
    return .{
        .id = @intCast(fbo),
        .texture = .{ .id = 0, .width = width, .height = height, .mipmaps = 1, .format = fmt },
        .depth = .{ .id = @intCast(depthTex), .width = width, .height = height, .mipmaps = 1, .format = fmt },
    };
}

fn drawScene() void {
    rl.drawPlane(v3(0, 0, 0), rl.Vector2{ .x = 40, .y = 40 }, rgba(120, 120, 130, 255));
    rl.drawCube(v3(0, 1.5, 0), 2, 3, 2, rgba(200, 80, 80, 255));
    rl.drawCube(v3(-5, 1, 3), 2, 2, 2, rgba(80, 160, 200, 255));
    rl.drawCube(v3(4, 1, -4), 2.5, 2, 2.5, rgba(90, 200, 120, 255));
    rl.drawSphere(v3(-4, 1.2, -4), 1.2, rgba(220, 200, 90, 255));
    rl.drawCube(v3(6, 0.75, 4), 1.5, 1.5, 1.5, rgba(200, 140, 220, 255));
}

pub fn run(shot: bool) void {
    if (shot) rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1280, 720, "torch: point light + cast shadows");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const shader = rl.loadShaderFromMemory(shadowVS, shadowFS) catch return;
    defer rl.unloadShader(shader);

    const loc_lightPos = rl.getShaderLocation(shader, "lightPos");
    const loc_lightColor = rl.getShaderLocation(shader, "lightColor");
    const loc_ambient = rl.getShaderLocation(shader, "ambient");
    const loc_viewPos = rl.getShaderLocation(shader, "viewPos");
    const loc_lightVP = rl.getShaderLocation(shader, "lightVP");
    const loc_shadowMap = rl.getShaderLocation(shader, "shadowMap");
    const loc_res = rl.getShaderLocation(shader, "shadowMapResolution");

    const lightColor = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    rl.setShaderValue(shader, loc_lightColor, &lightColor, .vec4);
    const ambient = [4]f32{ 0.7, 0.7, 0.85, 1.0 };
    rl.setShaderValue(shader, loc_ambient, &ambient, .vec4);
    const resv: i32 = SHADOWMAP_RESOLUTION;
    rl.setShaderValue(shader, loc_res, &resv, .int);

    const shadowMap = loadShadowmap(SHADOWMAP_RESOLUTION, SHADOWMAP_RESOLUTION);

    const cam = rl.Camera3D{
        .position = v3(14, 16, 14),
        .target = v3(0, 1.5, 0),
        .up = v3(0, 1, 0),
        .fovy = 45,
        .projection = .perspective,
    };

    var t: f32 = 0;
    var frame: i32 = 0;
    while (!rl.windowShouldClose()) {
        t += rl.getFrameTime();
        const lightPos = if (shot) v3(7, 11, 5) else v3(9 * @cos(t * 0.6), 11, 9 * @sin(t * 0.6));
        const lp = [3]f32{ lightPos.x, lightPos.y, lightPos.z };
        rl.setShaderValue(shader, loc_lightPos, &lp, .vec3);
        const vp = [3]f32{ cam.position.x, cam.position.y, cam.position.z };
        rl.setShaderValue(shader, loc_viewPos, &vp, .vec3);

        // The point light's shadow camera: perspective, FOV = the light's FOV.
        const lightCam = rl.Camera3D{
            .position = lightPos,
            .target = v3(0, 0, 0),
            .up = v3(0, 1, 0),
            .fovy = 90,
            .projection = .perspective,
        };

        // --- depth pass: scene depth from the light's POV ---
        const near = rl.gl.rlGetCullDistanceNear();
        const far = rl.gl.rlGetCullDistanceFar();
        rl.gl.rlSetClipPlanes(1.0, 45.0); // tight planes -> usable depth precision for the perspective light
        rl.beginTextureMode(shadowMap);
        rl.clearBackground(rl.Color.white);
        rl.beginMode3D(lightCam);
        const lightView = rl.gl.rlGetMatrixModelview();
        const lightProj = rl.gl.rlGetMatrixProjection();
        drawScene();
        rl.endMode3D();
        rl.endTextureMode();
        rl.gl.rlSetClipPlanes(near, far);
        const lightVP = rl.math.matrixMultiply(lightView, lightProj);
        rl.setShaderValueMatrix(shader, loc_lightVP, lightVP);

        // --- main pass: lit + shadowed ---
        rl.beginDrawing();
        rl.clearBackground(rgba(18, 18, 24, 255));
        rl.beginMode3D(cam);
        rl.beginShaderMode(shader);
        rl.gl.rlActiveTextureSlot(10);
        rl.gl.rlEnableTexture(@intCast(shadowMap.depth.id));
        const slot: i32 = 10;
        rl.setShaderValue(shader, loc_shadowMap, &slot, .int);
        drawScene();
        rl.endShaderMode();
        rl.drawSphere(lightPos, 0.4, rgba(255, 240, 180, 255)); // the light itself
        rl.endMode3D();
        rl.drawText("torch: point light + cast shadows (raylib shadowmap example, ported)", 20, 20, 20, rl.Color.ray_white);
        rl.drawFPS(20, 48);
        rl.endDrawing();

        if (shot) {
            frame += 1;
            if (frame >= 3) {
                rl.takeScreenshot("shot_demo.png");
                break;
            }
        }
    }
}
