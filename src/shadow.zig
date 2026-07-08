const rl = @import("raylib");
const state = @import("state.zig");
const render = @import("render.zig");
const lighting = @import("lighting.zig");
const mathx = @import("mathx.zig");

const GameState = state.GameState;
const v3 = mathx.v3;

// Cast shadows via a depth shadow map — the EXACT technique from the demo (raylib's
// official shadowmap example). Scene depth is rendered from the torch point light's
// POV each frame; the lighting shader compares against it. The light camera sits at
// the same torch position the light shader uses (hero + lighting.torchLightOffset).

pub const shadowSlot = 10;
pub const shadowRes = 2048;
const shadowNear = 1.0;
const shadowFar = 34.0;
const shadowFovy = 90.0;
const shadowCastRadius = 14.0; // only nearby casters cast (near the light -> short, attached shadows)

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

pub fn initShadows(g: *GameState) void {
    if (!g.lightLoaded) return; // shadows ride on the lighting shader

    const fbo = rl.gl.rlLoadFramebuffer();
    if (fbo == 0) return;
    const depthTex = rl.gl.rlLoadTextureDepth(shadowRes, shadowRes, false);
    rl.gl.rlFramebufferAttach(fbo, depthTex, 100, 100, 0); // RL_ATTACHMENT_DEPTH, RL_ATTACHMENT_TEXTURE2D
    const fmt = rl.PixelFormat.uncompressed_grayscale;
    g.shadowMap = rl.RenderTexture2D{
        .id = @intCast(fbo),
        .texture = .{ .id = 0, .width = shadowRes, .height = shadowRes, .mipmaps = 1, .format = fmt },
        .depth = .{ .id = @intCast(depthTex), .width = shadowRes, .height = shadowRes, .mipmaps = 1, .format = fmt },
    };

    const s = rl.loadShaderFromMemory(depthVS, depthFS) catch return;
    if (!rl.isShaderValid(s)) return;
    g.shadowShader = s;

    const slot: i32 = shadowSlot;
    rl.setShaderValue(g.lightShader, g.loc_shadowMap, &slot, .int);
    const res: i32 = shadowRes;
    rl.setShaderValue(g.lightShader, g.loc_res, &res, .int);
    g.shadowReady = true;
    g.shadowsOn = true;
}

pub fn unloadShadows(g: *GameState) void {
    if (g.shadowReady) {
        rl.unloadShader(g.shadowShader);
        rl.unloadRenderTexture(g.shadowMap);
        g.shadowReady = false;
    }
}

// The torch's shadow camera: a point light at hero + torchLightOffset, looking at
// the hero, wide FOV to cover the area. Matches the light shader's lightPos.
fn lightCamera(g: *GameState) rl.Camera3D {
    const t = g.player.Pos;
    const off = lighting.torchLightOffset;
    return .{
        .position = v3(t.x + off[0], t.y + off[1], t.z + off[2]),
        .target = t,
        .up = v3(0, 1, 0),
        .fovy = shadowFovy,
        .projection = .perspective,
    };
}

pub fn renderShadowMap(g: *GameState) void {
    if (!g.shadowsActive()) return;
    const cam = lightCamera(g);
    render.casterCull = shadowCastRadius;

    const near = rl.gl.rlGetCullDistanceNear();
    const far = rl.gl.rlGetCullDistanceFar();
    rl.gl.rlSetClipPlanes(shadowNear, shadowFar);

    rl.beginTextureMode(g.shadowMap);
    rl.clearBackground(rl.Color.white);
    rl.beginMode3D(cam);
    g.lightVP = rl.math.matrixMultiply(rl.gl.rlGetMatrixModelview(), rl.gl.rlGetMatrixProjection());
    rl.beginShaderMode(g.shadowShader);
    render.drawCasters(g);
    rl.endShaderMode();
    rl.endMode3D();
    rl.endTextureMode();

    rl.gl.rlSetClipPlanes(near, far);
    render.casterCull = 1e9;
}
