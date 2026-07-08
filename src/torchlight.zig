const std = @import("std");
const rl = @import("raylib");

// TORCHLIGHT — the approved torch lighting + cast-shadow + light-radius pipeline,
// copied VERBATIM from demo2.zig (the frozen reference demo). The shader source and
// every constant here are identical to the demo; do NOT alter the lighting math. The
// game feeds this its torch position, light radius, camera, and casters — nothing
// about the lighting itself changes between the demo and the game.

pub const SHADOWMAP_RESOLUTION = 6144;
pub const SHADOW_COVER_MARGIN = 1.3;

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

/// Everything the pipeline needs to place the torch this frame. The torch sits at
/// `pos` (above the player); the ground is assumed at y=0. `radius` is how far the
/// torch reaches before darkness.
pub const LightParams = struct {
    pos: rl.Vector3,
    radius: f32,
};

pub const Torch = struct {
    shadowMap: rl.RenderTexture2D,
    depthShader: rl.Shader,
    scene: rl.Shader,
    loc_lightPos: i32,
    loc_viewPos: i32,
    loc_lightVP: i32,
    loc_lightRadius: i32,
    lightVP: rl.Matrix = undefined,
    saved_near: @TypeOf(rl.gl.rlGetCullDistanceNear()) = 0,
    saved_far: @TypeOf(rl.gl.rlGetCullDistanceFar()) = 0,

    pub fn init() !Torch {
        const shadowMap = loadShadowmap(SHADOWMAP_RESOLUTION);
        const depthShader = try rl.loadShaderFromMemory(depthVS, depthFS);
        const scene = try rl.loadShaderFromMemory(sceneVS, sceneFS);

        // Constant uniforms, exactly as the demo sets them.
        const lc = [4]f32{ 1.0, 0.95, 0.85, 1.0 };
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "lightColor"), &lc, .vec4);
        const amb = [4]f32{ 0.6, 0.6, 0.7, 1.0 };
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "ambient"), &amb, .vec4);
        const res: i32 = SHADOWMAP_RESOLUTION;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMapResolution"), &res, .int);
        const slot: i32 = 10;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMap"), &slot, .int);

        return .{
            .shadowMap = shadowMap,
            .depthShader = depthShader,
            .scene = scene,
            .loc_lightPos = rl.getShaderLocation(scene, "lightPos"),
            .loc_viewPos = rl.getShaderLocation(scene, "viewPos"),
            .loc_lightVP = rl.getShaderLocation(scene, "lightVP"),
            .loc_lightRadius = rl.getShaderLocation(scene, "lightRadius"),
        };
    }

    pub fn deinit(self: *Torch) void {
        rl.unloadShader(self.depthShader);
        rl.unloadShader(self.scene);
        rl.unloadRenderTexture(self.shadowMap);
    }

    // The shadow camera: at the torch, looking straight down at the ground under it,
    // with a cone FOV sized to just cover the light radius (verbatim demo math).
    // `up` must not be parallel to the view direction or MatrixLookAt goes NaN.
    fn shadowCamera(lp: LightParams) rl.Camera3D {
        const coverTarget = lp.radius * SHADOW_COVER_MARGIN;
        const fovy = std.math.clamp(2.0 * std.math.atan(coverTarget / lp.pos.y) * (180.0 / std.math.pi), 30.0, 150.0);
        return .{
            .position = lp.pos,
            .target = .{ .x = lp.pos.x, .y = 0, .z = lp.pos.z },
            .up = .{ .x = 0, .y = 0, .z = -1 },
            .fovy = fovy,
            .projection = .perspective,
        };
    }

    // Depth pass: call this, draw the casters, then endShadowPass().
    pub fn beginShadowPass(self: *Torch, lp: LightParams) void {
        const cam = shadowCamera(lp);
        self.saved_near = rl.gl.rlGetCullDistanceNear();
        self.saved_far = rl.gl.rlGetCullDistanceFar();
        rl.gl.rlSetClipPlanes(1.0, 45.0);
        rl.beginTextureMode(self.shadowMap);
        rl.clearBackground(rl.Color.white);
        rl.beginMode3D(cam);
        self.lightVP = rl.math.matrixMultiply(rl.gl.rlGetMatrixModelview(), rl.gl.rlGetMatrixProjection());
        rl.beginShaderMode(self.depthShader);
    }

    pub fn endShadowPass(self: *Torch) void {
        rl.endShaderMode();
        rl.endMode3D();
        rl.endTextureMode();
        rl.gl.rlSetClipPlanes(self.saved_near, self.saved_far);
    }

    // Main pass: call after beginDrawing()+clear and BEFORE beginMode3D(cam).
    pub fn applyUniforms(self: *Torch, cam: rl.Camera3D, lp: LightParams) void {
        const p = [3]f32{ lp.pos.x, lp.pos.y, lp.pos.z };
        rl.setShaderValue(self.scene, self.loc_lightPos, &p, .vec3);
        const v = [3]f32{ cam.position.x, cam.position.y, cam.position.z };
        rl.setShaderValue(self.scene, self.loc_viewPos, &v, .vec3);
        const r = lp.radius;
        rl.setShaderValue(self.scene, self.loc_lightRadius, &r, .float);
        rl.setShaderValueMatrix(self.scene, self.loc_lightVP, self.lightVP);
    }

    // Wrap the lit geometry between beginScene()/endScene(), inside beginMode3D(cam).
    pub fn beginScene(self: *Torch) void {
        rl.beginShaderMode(self.scene);
        rl.gl.rlActiveTextureSlot(10);
        rl.gl.rlEnableTexture(@intCast(self.shadowMap.depth.id));
    }

    pub fn endScene(self: *Torch) void {
        _ = self;
        rl.endShaderMode();
    }
};
