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
// so both passes frame the same near/far slab around the light. NEAR bounds which
// casters exist to the map: anything above (light height - NEAR) is clipped out of
// the depth pass, so it must stay small enough that monster heads clear it under
// the lowered torch (0.4 leaves ~4.1 of caster headroom under a 4.5 light; the
// 32-bit depth target keeps precision fine at this ratio).
pub const SHADOW_CLIP_NEAR = 0.4;
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
    \\// Cheap hash / value noise over world XZ: mottles the flat vertex colors into
    \\// dirt, stone grain, and moss so broad surfaces don't read as untextured plastic.
    \\float hash21(vec2 p) {
    \\    p = fract(p*vec2(123.34, 456.21));
    \\    p += dot(p, p + 45.32);
    \\    return fract(p.x*p.y);
    \\}
    \\float vnoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f*f*(3.0 - 2.0*f);
    \\    return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
    \\               mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
    \\}
    \\// Fraction of this fragment in shadow (0 = lit, 1 = shadowed), from a wide 5x5
    \\// PCF tap. `spread` scales the kernel footprint past one texel so the penumbra
    \\// reads as a soft gradient rather than a hard stair-step. Shared by both lights.
    \\// The kernel is rotated per-fragment (hash of the pixel coord) so LARGE spreads
    \\// dissolve into grain instead of banding into 25 ghost images — that grain is
    \\// what lets the distance-blur below stay at 25 taps instead of needing more.
    \\float shadowFrac(sampler2D map, mat4 vp, float res, float ndl, float spread) {
    \\    vec4 p = vp*vec4(fragPosition, 1.0);
    \\    p.xyz /= p.w;
    \\    p.xyz = p.xyz*0.5 + 0.5;
    \\    if (p.z > 1.0 || p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 0.0;
    \\    // Wider kernels sample depth farther from the fragment, so the acne bias
    \\    // must grow with the footprint (tuned so spread 1.7 keeps its old bias).
    \\    float bias = max(0.0025*(1.0 - ndl), 0.0007)*(0.4 + 0.35*spread);
    \\    float texel = 1.0/res;
    \\    float ra = hash21(gl_FragCoord.xy)*6.2831853;
    \\    vec2 rot = vec2(cos(ra), sin(ra));
    \\    float sc = 0.0;
    \\    for (int x = -2; x <= 2; x++)
    \\        for (int y = -2; y <= 2; y++) {
    \\            vec2 o = vec2(x, y);
    \\            o = vec2(o.x*rot.x - o.y*rot.y, o.x*rot.y + o.y*rot.x);
    \\            if (p.z - bias > texture(map, p.xy + o*texel*spread).r) sc += 1.0;
    \\        }
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
    \\    // GROUND GRAIN: two octaves of world-space value noise break the flat vertex
    \\    // colors into mottled dirt/stone. Strongest on upward faces (the floor, boulder
    \\    // tops), gentler on walls and bodies so verticals keep their clean silhouette.
    \\    float upMask = smoothstep(0.25, 0.95, normal.y);
    \\    float grain = vnoise(fragPosition.xz*0.85)*0.55 + vnoise(fragPosition.xz*3.9)*0.45;
    \\    float gstr = mix(0.12, 0.30, upMask);
    \\    vec3 albedo = texelColor.rgb*fragColor.rgb*(1.0 - gstr + 2.0*gstr*grain);
    \\    // DIRT PATCHES: one very low-frequency octave drifts the floor hue between
    \\    // mossy-cool and dry-warm across meters, so the arena floor reads as ground
    \\    // that weathered differently place to place, not one uniform carpet. Ground
    \\    // only (up-faces) so walls and bodies keep their true tints.
    \\    float patch = vnoise(fragPosition.xz*0.11);
    \\    vec3 patchTint = mix(vec3(0.90, 1.03, 0.90), vec3(1.08, 0.99, 0.90), patch);
    \\    albedo *= mix(vec3(1.0), patchTint, upMask);
    \\    // CRACKED EARTH: a ridged octave etches thin dark fissure lines into the
    \\    // floor, gated to the DRY patches (the mask keys off its own low-frequency
    \\    // field) — parched ground splits into a vein network, mossy ground doesn't.
    \\    float ridge = abs(vnoise(fragPosition.xz*0.9 + 17.3) - 0.5)*2.0;
    \\    float crackMask = smoothstep(0.45, 0.8, vnoise(fragPosition.xz*0.13 + 5.1));
    \\    float crack = (1.0 - smoothstep(0.0, 0.10, ridge))*crackMask;
    \\    albedo *= 1.0 - 0.34*crack*upMask;
    \\    vec3 l = normalize(lightPos - fragPosition);
    \\    float NdotL = max(dot(normal, l), 0.0);
    \\    vec3 lightDot = lightColor.rgb*NdotL;
    \\    // Purely diffuse (Lambert): the specular term is gone so the flat ground no
    \\    // longer flares a bright hot-spot under the overhead torch. Matte surfaces.
    \\    finalColor = vec4(albedo*lightDot, 1.0);
    \\    // PENUMBRA GROWTH: a torch is a fat flame, not a point — shadows stand crisp
    \\    // at the carrier's feet and diffuse toward the rim of the light. Scaling the
    \\    // PCF footprint with distance from the light axis fakes PCSS at zero extra
    \\    // taps (the per-fragment kernel rotation above hides the undersampling).
    \\    float lightDist = length(fragPosition.xz - lightPos.xz);
    \\    float torchSpread = mix(1.0, 7.0, smoothstep(0.0, lightRadius, lightDist));
    \\    float sTorch = shadowFrac(shadowMap, lightVP, float(shadowMapResolution), dot(normal, l), torchSpread);
    \\    finalColor = mix(finalColor, vec4(0, 0, 0, 1), sTorch);
    \\    finalColor.rgb += albedo*(ambient.rgb/10.0);
    \\    // ACTIVE DISC: your torch only reaches so far. `active` is 1 at the hero and
    \\    // fades to 0 at the torch radius (horizontal distance from the torch axis = you),
    \\    // so it reads as a disc of light. Everything above is the fully lit "active"
    \\    // look; past the disc we fall back to the fog-of-war memory below.
    \\    float active = 1.0 - smoothstep(lightRadius*0.65, lightRadius, lightDist);
    \\    // COLOR TEMPERATURE: firelight is warmest at its heart and cools as it thins
    \\    // out, so the disc grades from golden center to blue-grey rim instead of one
    \\    // flat tone. Cheap, but it sells "torch" more than anything else here.
    \\    float core = 1.0 - smoothstep(0.0, lightRadius*0.95, lightDist);
    \\    finalColor.rgb *= mix(vec3(0.74, 0.82, 1.10), vec3(1.10, 1.00, 0.86), core);
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
    \\        // The bolt's shadows blur with distance too, on its smaller radius.
    \\        float fireSpread = mix(1.2, 5.5, clamp(fd/fireRadius, 0.0, 1.0));
    \\        float fs = shadowFrac(fireMap, fireVP, float(fireMapResolution), fNdotL, fireSpread);
    \\        finalColor.rgb += albedo*fireColor*(fNdotL*0.85 + 0.15)*atten*fireIntensity*(1.0 - fs);
    \\    }
    \\    finalColor = pow(finalColor, vec4(1.0/2.2));
    \\    // DITHER: +-1 LSB of screen-space noise after gamma. The torch falloff spans
    \\    // many near-black gradients that band visibly on an 8-bit target; this breaks
    \\    // the bands up into imperceptible grain.
    \\    finalColor.rgb += (hash21(gl_FragCoord.xy) - 0.5)*(2.0/255.0);
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
/// `pos` (above the player); `groundRef` is the walkable ground height under it
/// (0 on the flat floor, the ledge height on a rampart) — the overhead shadow
/// camera aims at and sizes its cone against THAT plane, so standing on raised
/// ground doesn't shrink the shadowed footprint. `radius` is how far the torch
/// reaches before darkness.
pub const LightParams = struct {
    pos: rl.Vector3,
    radius: f32,
    groundRef: f32 = 0,
};

/// A moving fireball light. `pos` sits above the projectile (like the torch, an
/// overhead pool so its downward shadow map is well-oriented); `groundRef` as in
/// LightParams; `intensity` of 0 disables it entirely (no light, no shadow,
/// second depth pass skipped).
pub const FireParams = struct {
    pos: rl.Vector3,
    radius: f32,
    color: rl.Vector3,
    intensity: f32,
    groundRef: f32 = 0,
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
        return overheadCamera(lp.pos, lp.radius, lp.groundRef);
    }

    // Shared by the torch and the fireball: an overhead light looking straight down,
    // its cone FOV sized to just cover `radius` on the LOCAL ground plane (groundY)
    // — sizing against absolute y=0 would shrink the covered disc whenever the
    // light stands on raised terrain.
    fn overheadCamera(pos: rl.Vector3, radius: f32, groundY: f32) rl.Camera3D {
        const coverTarget = radius * SHADOW_COVER_MARGIN;
        const height = @max(pos.y - groundY, 0.5);
        const fovy = std.math.clamp(2.0 * std.math.atan(coverTarget / height) * (180.0 / std.math.pi), 30.0, 150.0);
        return .{
            .position = pos,
            .target = .{ .x = pos.x, .y = groundY, .z = pos.z },
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
        const cam = overheadCamera(fp.pos, fp.radius, fp.groundRef);
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

    // Per-area torch personality: each area re-tints the light itself (a touch warmer,
    // paler, sicklier...) so the SAME torch pipeline gives every floor its own night.
    // Called once per area transition, not per frame.
    pub fn setLightColor(self: *Torch, rgb: [3]f32) void {
        const lc = [4]f32{ rgb[0], rgb[1], rgb[2], 1.0 };
        rl.setShaderValue(self.scene, rl.getShaderLocation(self.scene, "lightColor"), &lc, .vec4);
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
