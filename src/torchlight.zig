const std = @import("std");
const rl = @import("raylib");

// TORCHLIGHT — the approved torch lighting + cast-shadow + light-radius pipeline,
// originally copied VERBATIM from demo2.zig (the frozen reference demo). It now
// intentionally diverges from the demo in TWO ways: (1) the scene shader is purely
// diffuse (the demo's specular term was removed) so the flat ground no longer flares a
// bright specular hot-spot under the overhead torch; (2) past the torch disc the shader
// no longer fades straight to black — it falls back to the fog-of-war memory layer
// (fog.zig), so explored ground stays a dim, cool "seen" instead of vanishing. The
// cast-shadow PCF and the fireball light are otherwise unchanged from the demo. The
// game feeds this its torch position, light radius, camera, casters, and fog map.

// The torch only lights a small disc. 4096 gives the soft-PCF penumbra a crisp base
// to blur from (so edges read as soft, not chunky) while still costing far less depth
// fill than the demo's 6144. Lighting math is otherwise unchanged.
pub const SHADOWMAP_RESOLUTION = 4096;
pub const SHADOW_COVER_MARGIN = 1.3;

// Depth-pass clip planes for the overhead shadow cameras (torch + fireball). Shared
// so both passes frame the same near/far slab around the light.
pub const SHADOW_CLIP_NEAR = 1.0;
pub const SHADOW_CLIP_FAR = 45.0;

// The fireball's shadow pool is a fraction of the torch's, so a small map keeps its
// second depth pass cheap while its soft PCF hides the lower resolution.
pub const FIRE_SHADOWMAP_RESOLUTION = 1024;

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
    \\uniform sampler2D fogMap;
    \\uniform float fogHalf;
    \\uniform mat4 fireVP;
    \\uniform sampler2D fireMap;
    \\uniform int fireMapResolution;
    \\uniform vec3 firePos;
    \\uniform vec3 fireColor;
    \\uniform float fireRadius;
    \\uniform float fireIntensity;
    \\out vec4 finalColor;
    \\// Fraction of this fragment in shadow (0 = lit, 1 = shadowed), from a wide 5x5
    \\// PCF tap. `spread` scales the kernel footprint past one texel so the penumbra
    \\// reads as a soft gradient rather than a hard stair-step. Shared by both lights.
    \\float shadowFrac(sampler2D map, mat4 vp, float res, float ndl, float spread) {
    \\    vec4 p = vp*vec4(fragPosition, 1.0);
    \\    p.xyz /= p.w;
    \\    p.xyz = p.xyz*0.5 + 0.5;
    \\    if (p.z > 1.0 || p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 0.0;
    \\    float bias = max(0.0025*(1.0 - ndl), 0.0007);
    \\    float texel = 1.0/res;
    \\    float sc = 0.0;
    \\    for (int x = -2; x <= 2; x++)
    \\        for (int y = -2; y <= 2; y++)
    \\            if (p.z - bias > texture(map, p.xy + vec2(x, y)*texel*spread).r) sc += 1.0;
    \\    // Fade the shadow out RADIALLY toward the edge of the map's footprint so it
    \\    // dissolves into the dark instead of ending on a hard circular cutoff at the
    \\    // coverage boundary. length(p.xy - 0.5) is the map-UV distance from the light
    \\    // axis; 0.5 is the edge of the covered disc. Also masks edge PCF taps that would
    \\    // otherwise sample past the map border.
    \\    float edgeFade = 1.0 - smoothstep(0.36, 0.49, length(p.xy - 0.5));
    \\    return sc/25.0 * edgeFade;
    \\}
    \\void main() {
    \\    vec4 texelColor = texture(texture0, fragTexCoord);
    \\    vec3 normal = normalize(fragNormal);
    \\    vec3 l = normalize(lightPos - fragPosition);
    \\    float NdotL = max(dot(normal, l), 0.0);
    \\    vec3 lightDot = lightColor.rgb*NdotL;
    \\    // Purely diffuse (Lambert): the specular term is gone so the flat ground no
    \\    // longer flares a bright hot-spot under the overhead torch. Matte surfaces.
    \\    finalColor = texelColor*fragColor*vec4(lightDot, 1.0);
    \\    float sTorch = shadowFrac(shadowMap, lightVP, float(shadowMapResolution), dot(normal, l), 1.7);
    \\    finalColor = mix(finalColor, vec4(0, 0, 0, 1), sTorch);
    \\    finalColor += texelColor*(ambient/10.0)*fragColor;
    \\    // ACTIVE DISC: your torch only reaches so far. `active` is 1 at the hero and
    \\    // fades to 0 at the torch radius (horizontal distance from the torch axis = you),
    \\    // so it reads as a disc of light. Everything above is the fully lit "active"
    \\    // look; past the disc we fall back to the fog-of-war memory below.
    \\    float lightDist = length(fragPosition.xz - lightPos.xz);
    \\    float active = 1.0 - smoothstep(lightRadius*0.65, lightRadius, lightDist);
    \\    // FOG OF WAR: persistent exploration at this ground point (0 unseen .. 1 seen).
    \\    // The arena spans [-fogHalf, fogHalf] on X/Z; map that onto the [0,1] fog map.
    \\    vec2 fogUV = fragPosition.xz/(2.0*fogHalf) + 0.5;
    \\    float seen = texture(fogMap, fogUV).r;
    \\    // SEEN: a dim, cool, desaturated memory of the lit terrain -- drained toward
    \\    // grey, tinted cool, and darkened -- clearly distinct from the warm active disc.
    \\    // Unseen ground (seen = 0) collapses to black, so the world genuinely hides.
    \\    float luma = dot(finalColor.rgb, vec3(0.299, 0.587, 0.114));
    \\    vec3 memory = mix(vec3(luma), finalColor.rgb, 0.25)*vec3(0.55, 0.70, 1.0);
    \\    vec3 seenColor = memory*0.16*seen;
    \\    finalColor.rgb = mix(seenColor, finalColor.rgb, active);
    \\    // FIREBALL: a second moving light, added AFTER the fog blend so a fireball
    \\    // hurled into the dark still lights the walls + ground it flies past (even
    \\    // unexplored ground it has never revealed).
    \\    // Own smooth distance falloff, own soft cast shadow (fireMap).
    \\    if (fireIntensity > 0.0) {
    \\        vec3 fl = normalize(firePos - fragPosition);
    \\        float fNdotL = max(dot(normal, fl), 0.0);
    \\        float fd = length(firePos - fragPosition);
    \\        float atten = clamp(1.0 - fd/fireRadius, 0.0, 1.0);
    \\        atten *= atten;
    \\        float fs = shadowFrac(fireMap, fireVP, float(fireMapResolution), fNdotL, 1.7);
    \\        finalColor.rgb += texelColor.rgb*fireColor*(fNdotL*0.85 + 0.15)*atten*fireIntensity*(1.0 - fs);
    \\    }
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

/// A moving fireball light. `pos` sits above the projectile (like the torch, an
/// overhead pool so its downward shadow map is well-oriented); `intensity` of 0
/// disables it entirely (no light, no shadow, second depth pass skipped).
pub const FireParams = struct {
    pos: rl.Vector3,
    radius: f32,
    color: rl.Vector3,
    intensity: f32,
};

/// The fog-of-war memory layer sampled by the scene shader. `texId` is the GPU id of a
/// grayscale exploration map (see fog.zig); `half` is the arena half-extent it covers,
/// so the shader can map a fragment's XZ into the map's [0,1] range.
pub const FogParams = struct {
    texId: u32,
    half: f32,
};

pub const Torch = struct {
    shadowMap: rl.RenderTexture2D,
    fireMap: rl.RenderTexture2D,
    depthShader: rl.Shader,
    scene: rl.Shader,
    loc_lightPos: i32,
    loc_viewPos: i32,
    loc_lightVP: i32,
    loc_lightRadius: i32,
    loc_fogHalf: i32,
    loc_fireVP: i32,
    loc_firePos: i32,
    loc_fireColor: i32,
    loc_fireRadius: i32,
    loc_fireIntensity: i32,
    lightVP: rl.Matrix = undefined,
    fireVP: rl.Matrix = undefined,
    fogTexId: u32 = 0, // GPU id of the fog map to bind on slot 12; set by applyFogUniforms
    saved_near: @TypeOf(rl.gl.rlGetCullDistanceNear()) = 0,
    saved_far: @TypeOf(rl.gl.rlGetCullDistanceFar()) = 0,

    pub fn init() !Torch {
        const shadowMap = loadShadowmap(SHADOWMAP_RESOLUTION);
        const fireMap = loadShadowmap(FIRE_SHADOWMAP_RESOLUTION);
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
        const fres: i32 = FIRE_SHADOWMAP_RESOLUTION;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fireMapResolution"), &fres, .int);
        const fslot: i32 = 11;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fireMap"), &fslot, .int);
        const fogslot: i32 = 12;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fogMap"), &fogslot, .int);

        return .{
            .shadowMap = shadowMap,
            .fireMap = fireMap,
            .depthShader = depthShader,
            .scene = scene,
            .loc_lightPos = rl.getShaderLocation(scene, "lightPos"),
            .loc_viewPos = rl.getShaderLocation(scene, "viewPos"),
            .loc_lightVP = rl.getShaderLocation(scene, "lightVP"),
            .loc_lightRadius = rl.getShaderLocation(scene, "lightRadius"),
            .loc_fogHalf = rl.getShaderLocation(scene, "fogHalf"),
            .loc_fireVP = rl.getShaderLocation(scene, "fireVP"),
            .loc_firePos = rl.getShaderLocation(scene, "firePos"),
            .loc_fireColor = rl.getShaderLocation(scene, "fireColor"),
            .loc_fireRadius = rl.getShaderLocation(scene, "fireRadius"),
            .loc_fireIntensity = rl.getShaderLocation(scene, "fireIntensity"),
            // Seed both light matrices to identity: applyFireUniforms uploads fireVP
            // every frame, including before the first fireball sets it in a depth pass.
            .lightVP = rl.math.matrixIdentity(),
            .fireVP = rl.math.matrixIdentity(),
        };
    }

    pub fn deinit(self: *Torch) void {
        rl.unloadShader(self.depthShader);
        rl.unloadShader(self.scene);
        rl.unloadRenderTexture(self.shadowMap);
        rl.unloadRenderTexture(self.fireMap);
    }

    // The shadow camera: at the torch, looking straight down at the ground under it,
    // with a cone FOV sized to just cover the light radius (verbatim demo math).
    // `up` must not be parallel to the view direction or MatrixLookAt goes NaN.
    fn shadowCamera(lp: LightParams) rl.Camera3D {
        return overheadCamera(lp.pos, lp.radius);
    }

    // Shared by the torch and the fireball: an overhead light looking straight down,
    // its cone FOV sized to just cover `radius` on the ground (verbatim demo math).
    fn overheadCamera(pos: rl.Vector3, radius: f32) rl.Camera3D {
        const coverTarget = radius * SHADOW_COVER_MARGIN;
        const fovy = std.math.clamp(2.0 * std.math.atan(coverTarget / pos.y) * (180.0 / std.math.pi), 30.0, 150.0);
        return .{
            .position = pos,
            .target = .{ .x = pos.x, .y = 0, .z = pos.z },
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
        rl.gl.rlSetClipPlanes(SHADOW_CLIP_NEAR, SHADOW_CLIP_FAR);
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

    // Fireball depth pass: only worth running when a fireball is live (fp.intensity>0).
    // Same structure as the torch pass, into the smaller fireMap from the fireball's
    // overhead camera. Draw the casters between this and endFireShadowPass().
    pub fn beginFireShadowPass(self: *Torch, fp: FireParams) void {
        const cam = overheadCamera(fp.pos, fp.radius);
        self.saved_near = rl.gl.rlGetCullDistanceNear();
        self.saved_far = rl.gl.rlGetCullDistanceFar();
        rl.gl.rlSetClipPlanes(SHADOW_CLIP_NEAR, SHADOW_CLIP_FAR);
        rl.beginTextureMode(self.fireMap);
        rl.clearBackground(rl.Color.white);
        rl.beginMode3D(cam);
        self.fireVP = rl.math.matrixMultiply(rl.gl.rlGetMatrixModelview(), rl.gl.rlGetMatrixProjection());
        rl.beginShaderMode(self.depthShader);
    }

    pub fn endFireShadowPass(self: *Torch) void {
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

    // Fireball light uniforms. Pass intensity 0 (any pos/radius/color) when no
    // fireball is live; the scene shader then skips the whole fireball term.
    pub fn applyFireUniforms(self: *Torch, fp: FireParams) void {
        const p = [3]f32{ fp.pos.x, fp.pos.y, fp.pos.z };
        rl.setShaderValue(self.scene, self.loc_firePos, &p, .vec3);
        const c = [3]f32{ fp.color.x, fp.color.y, fp.color.z };
        rl.setShaderValue(self.scene, self.loc_fireColor, &c, .vec3);
        const r = fp.radius;
        rl.setShaderValue(self.scene, self.loc_fireRadius, &r, .float);
        const i = fp.intensity;
        rl.setShaderValue(self.scene, self.loc_fireIntensity, &i, .float);
        rl.setShaderValueMatrix(self.scene, self.loc_fireVP, self.fireVP);
    }

    // Fog-of-war uniforms. Stash the map's GPU id for beginScene to bind on slot 12,
    // and upload the arena half-extent so the shader can map fragments into the map.
    pub fn applyFogUniforms(self: *Torch, fog: FogParams) void {
        self.fogTexId = fog.texId;
        const h = fog.half;
        rl.setShaderValue(self.scene, self.loc_fogHalf, &h, .float);
    }

    // Wrap the lit geometry between beginScene()/endScene(), inside beginMode3D(cam).
    pub fn beginScene(self: *Torch) void {
        rl.beginShaderMode(self.scene);
        rl.gl.rlActiveTextureSlot(10);
        rl.gl.rlEnableTexture(@intCast(self.shadowMap.depth.id));
        rl.gl.rlActiveTextureSlot(11);
        rl.gl.rlEnableTexture(@intCast(self.fireMap.depth.id));
        rl.gl.rlActiveTextureSlot(12);
        rl.gl.rlEnableTexture(self.fogTexId);
    }

    pub fn endScene(self: *Torch) void {
        _ = self;
        rl.endShaderMode();
    }
};
