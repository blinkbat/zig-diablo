const std = @import("std");
const rl = @import("raylib");
const world = @import("world.zig");

// TORCHLIGHT — torch lighting + cast-shadow + light-radius pipeline, adapted from
// demo2.zig. Two deliberate divergences from the demo: (1) the scene shader is purely
// diffuse (specular removed) so flat ground doesn't flare a hot-spot under the torch;
// (2) past the torch disc the shader falls back to the fog-of-war memory layer
// (fog.zig) instead of black, so explored ground stays a dim, cool "seen". The game
// feeds this its torch position, radius, camera, casters, and fog map.

// The torch lights a small disc. 4096 gives the soft-PCF penumbra a crisp base to blur
// from while costing far less depth fill than the demo's 6144.
pub const SHADOWMAP_RESOLUTION = 4096;
pub const SHADOW_COVER_MARGIN = 1.3;

// Default warm torch tint. The per-map `light:` falls back to this, and the scene
// shader seeds its lightColor uniform with it — one source so the two can't drift.
pub const DEFAULT_LIGHT = [3]f32{ 1.0, 0.95, 0.85 };

// Depth-pass clip planes for the overhead shadow cameras (torch + fireball), shared
// so both frame the same near/far slab. NEAR clips anything above (light height -
// NEAR) out of the depth pass, so it must stay small enough that monster heads clear
// it under the lowered torch (0.4 leaves ~4.1 headroom under a 4.5 light; the 32-bit
// depth target keeps precision fine at this ratio).
pub const SHADOW_CLIP_NEAR = 0.4;
pub const SHADOW_CLIP_FAR = 45.0;

// The fireball's shadow pool is a fraction of the torch's, keeping its second depth
// pass cheap while soft PCF hides the lower resolution.
pub const FIRE_SHADOWMAP_RESOLUTION = 1024;

// GPU texture units the scene shader's samplers are pinned to. Set as a uniform ONCE
// in init() and re-bound every frame in beginScene(); upload and bind MUST use the
// same number or a sampler reads the wrong texture. Named so the two sites can't drift.
const SLOT_SHADOW: i32 = 10;
const SLOT_FIRE: i32 = 11;
const SLOT_FOG: i32 = 12;

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
    \\uniform mat4 lightVP;
    \\uniform sampler2D shadowMap;
    \\uniform int shadowMapResolution;
    \\uniform float lightRadius;
    \\uniform sampler2D fogMap;
    \\uniform vec2 fogHalf; // arena half-extents (w, d): rectangular arenas
    \\uniform mat4 fireVP;
    \\uniform sampler2D fireMap;
    \\uniform int fireMapResolution;
    \\uniform vec3 firePos;
    \\uniform vec3 fireColor;
    \\uniform float fireRadius;
    \\uniform float fireIntensity;
    \\uniform ivec3 floorMats;
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
    \\// ---- FLOOR MATERIALS ----
    \\// One procedural look per world.FloorMat, ids matching that enum's order (its
    \\// base() tones mirror these — keep in sync). Pre-gamma albedo at a ground point.
    \\// Crisp world-grid speckle: the sharp octave smooth vnoise lacks — without it
    \\// broad ground reads as out-of-focus blur.
    \\float speck(vec2 p, float s) { return hash21(floor(p*s)); }
    \\// fwidth-antialiased step: edges stay crisp up close and soften with distance
    \\// instead of shimmering.
    \\float aastep(float e, float x) { float w = max(fwidth(x), 1e-4); return smoothstep(e - w, e + w, x); }
    \\vec3 matAlbedo(int id, vec2 p) {
    \\    if (id == 1) { // GRASS: fine blade grain over sickly green, whole patches dead
    \\        float blades = vnoise(p*6.5)*0.40 + vnoise(p*13.0)*0.28 + speck(p, 21.0)*0.32;
    \\        float dead = smoothstep(0.35, 0.75, vnoise(p*0.09 + 3.7));
    \\        vec3 c = mix(vec3(0.13, 0.18, 0.09), vec3(0.25, 0.21, 0.11), dead);
    \\        return c*(0.62 + 0.76*blades);
    \\    }
    \\    if (id == 2) { // STONE: worn slabs, dark grout seams, moss creeping in the damp
    \\        vec2 gp = p*0.42;
    \\        vec2 f = fract(gp);
    \\        float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    \\        float tone = 0.76 + 0.46*hash21(floor(gp));
    \\        vec3 c = vec3(0.235, 0.230, 0.215)*tone*(0.85 + 0.30*vnoise(p*2.7))*(0.90 + 0.20*speck(p, 17.0));
    \\        float moss = smoothstep(0.55, 0.85, vnoise(p*0.23 + 7.7));
    \\        c = mix(c, vec3(0.11, 0.15, 0.08), moss*0.55);
    \\        c *= 0.82 + 0.18*aastep(0.085, d); // shaded bevel ring inside the seam
    \\        return mix(c*0.30, c, aastep(0.032, d));
    \\    }
    \\    if (id == 3) { // COBBLE: staggered rounded stones over dark packed earth
    \\        vec2 gp = p*1.15;
    \\        gp.x += 0.5*step(0.5, fract(gp.y*0.5));
    \\        vec2 f = fract(gp) - 0.5;
    \\        float r = length(f*vec2(1.0, 1.25));
    \\        vec3 rock = vec3(0.225, 0.215, 0.195)*(0.72 + 0.56*hash21(floor(gp)))*(0.86 + 0.16*vnoise(p*4.0))*(0.90 + 0.20*speck(p, 15.0));
    \\        rock *= 1.0 - 0.38*smoothstep(0.16, 0.43, r); // domed tops shade toward the rim
    \\        return mix(vec3(0.095, 0.080, 0.055), rock, 1.0 - aastep(0.43, r));
    \\    }
    \\    if (id == 4) { // MUD: near-black wet earth, broad standing-water darkening
    \\        float pool = smoothstep(0.35, 0.80, vnoise(p*0.35 + 21.0));
    \\        vec3 c = mix(vec3(0.155, 0.120, 0.080), vec3(0.070, 0.055, 0.040), pool);
    \\        c *= 0.80 + 0.40*vnoise(p*2.3);
    \\        return c*(0.93 + 0.14*speck(p, 13.0)); // wet grit — mud stays smoother than stone
    \\    }
    \\    if (id == 5) { // BONE: ash-dark ground littered with clumped pale fragments
    \\        vec3 ash = vec3(0.125, 0.110, 0.095)*(0.75 + 0.50*vnoise(p*1.7))*(0.92 + 0.16*speck(p, 19.0));
    \\        float bones = smoothstep(0.80, 0.90, vnoise(p*7.5 + 9.1)*0.55 + vnoise(p*0.5 + 3.3)*0.50);
    \\        return mix(ash, vec3(0.50, 0.47, 0.39), bones);
    \\    }
    \\    // DIRT (0, and the fallback): weathers moss-sick to blood-rust; dry patches
    \\    // split into a cracked vein network (parched earth), mossy ground doesn't.
    \\    float grain = vnoise(p*0.85)*0.42 + vnoise(p*3.9)*0.33 + speck(p, 19.0)*0.25;
    \\    float dry = vnoise(p*0.11);
    \\    vec3 c = vec3(0.235, 0.195, 0.145)*mix(vec3(0.74, 0.92, 0.72), vec3(1.05, 0.80, 0.64), dry);
    \\    c *= 0.70 + 0.60*grain;
    \\    float ridge = abs(vnoise(p*0.9 + 17.3) - 0.5)*2.0;
    \\    float crack = (1.0 - smoothstep(0.0, 0.07, ridge))*smoothstep(0.45, 0.8, vnoise(p*0.13 + 5.1));
    \\    return c*(1.0 - 0.52*crack);
    \\}
    \\// The area's three materials blended across the ground by two low-frequency
    \\// fields, each border roughened by a mid-frequency octave so transitions read as
    \\// ragged terrain edges, not contour lines. Pure function of world XZ: the same
    \\// patches every load, no stored data.
    \\vec3 floorAlbedo(vec2 p) {
    \\    float n1 = vnoise(p*0.050) + (vnoise(p*0.55 + 2.2) - 0.5)*0.26;
    \\    float w1 = smoothstep(0.50, 0.64, n1);
    \\    float n2 = vnoise(p*0.031 + 40.0) + (vnoise(p*0.63 + 11.0) - 0.5)*0.22;
    \\    float w2 = smoothstep(0.66, 0.78, n2);
    \\    vec3 c = mix(matAlbedo(floorMats.x, p), matAlbedo(floorMats.y, p), w1);
    \\    c = mix(c, matAlbedo(floorMats.z, p), w2);
    \\    // DAMP BLOTCHES: one very low octave sinks whole stretches toward wet-dark
    \\    // so the midfield never reads as a single carpet (darken-only).
    \\    return c*(0.72 + 0.28*vnoise(p*0.045 + 9.7));
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
    \\    float upMask = smoothstep(0.25, 0.95, normal.y);
    \\    // FLOOR SENTINEL: baked walkable ground carries a NEGATIVE texcoord u
    \\    // (-1 = blended material field, -2 = masonry pavement on ledge caps / ramp
    \\    // tops). raylib's immediate-mode draws only emit u >= 0, so props and bodies
    \\    // can never trip the flag. (The default 1x1 white texture samples white at
    \\    // any uv, so texture0 stays valid for flagged fragments too.)
    \\    vec3 albedo;
    \\    if (fragTexCoord.x < -1.5) {
    \\        albedo = matAlbedo(2, fragPosition.xz)*fragColor.rgb; // built pavement is stone
    \\    } else if (fragTexCoord.x < -0.5) {
    \\        albedo = floorAlbedo(fragPosition.xz)*fragColor.rgb;
    \\    } else {
    \\        // PROPS/BODIES: a light 2-octave grain so broad surfaces don't read as
    \\        // untextured plastic — strongest on up-faces, gentle on silhouettes.
    \\        float grain = vnoise(fragPosition.xz*0.85)*0.55 + vnoise(fragPosition.xz*3.9)*0.45;
    \\        float gstr = mix(0.12, 0.24, upMask);
    \\        albedo = texelColor.rgb*fragColor.rgb*(1.0 - gstr + 2.0*gstr*grain);
    \\    }
    \\    vec3 l = normalize(lightPos - fragPosition);
    \\    float NdotL = max(dot(normal, l), 0.0);
    \\    // RADIAL FALLOFF: torchlight pools at the carrier and starves toward the rim
    \\    // instead of filling the disc edge-to-edge like a floodlight — the bright
    \\    // island in oppressive dark is most of the Diablo look. Post-gamma this curve
    \\    // still leaves the mid-disc readable (~0.6 of core).
    \\    float lightDist = length(fragPosition.xz - lightPos.xz);
    \\    float torchAtten = pow(max(1.0 - lightDist/max(lightRadius, 0.001), 0.0), 1.5);
    \\    vec3 lightDot = lightColor.rgb*NdotL*torchAtten;
    \\    // Unattenuated lit value, kept aside for the fog-of-war memory below: the
    \\    // "seen" band must not inherit the torch falloff or explored ground past the
    \\    // disc would black out with it.
    \\    vec3 memBase = albedo*(lightColor.rgb*NdotL + 0.05);
    \\    // Purely diffuse (Lambert): the specular term is gone so the flat ground no
    \\    // longer flares a bright hot-spot under the overhead torch. Matte surfaces.
    \\    finalColor = vec4(albedo*lightDot, 1.0);
    \\    // PENUMBRA GROWTH: a torch is a fat flame, not a point — shadows stand crisp
    \\    // at the carrier's feet and diffuse toward the rim of the light. Scaling the
    \\    // PCF footprint with distance from the light axis fakes PCSS at zero extra
    \\    // taps (the per-fragment kernel rotation above hides the undersampling).
    \\    float torchSpread = mix(1.0, 7.0, smoothstep(0.0, lightRadius, lightDist));
    \\    float sTorch = shadowFrac(shadowMap, lightVP, float(shadowMapResolution), dot(normal, l), torchSpread);
    \\    finalColor = mix(finalColor, vec4(0, 0, 0, 1), sTorch);
    \\    finalColor.rgb += albedo*(ambient.rgb/10.0);
    \\    // ACTIVE DISC: your torch only reaches so far. `active` is 1 at the hero and
    \\    // fades to 0 at the torch radius (horizontal distance from the torch axis = you),
    \\    // so it reads as a disc of light. Everything above is the fully lit "active"
    \\    // look; past the disc we fall back to the fog-of-war memory below.
    \\    float litDisc = 1.0 - smoothstep(lightRadius*0.65, lightRadius, lightDist); // NOT 'active' — reserved GLSL keyword
    \\    // COLOR TEMPERATURE: firelight is warmest at its heart and cools as it thins
    \\    // out, so the disc grades from golden center to blue-grey rim instead of one
    \\    // flat tone. Cheap, but it sells "torch" more than anything else here.
    \\    float core = 1.0 - smoothstep(0.0, lightRadius*0.95, lightDist);
    \\    // Rim leans sickly grey-green (not clean moonlight blue): the dark past the
    \\    // flame should feel diseased, the core a touch more amber against it.
    \\    finalColor.rgb *= mix(vec3(0.60, 0.72, 0.74), vec3(1.13, 0.99, 0.80), core);
    \\    // MURK GRADE: drain saturation as the light thins — color lives near the
    \\    // flame, the rim decays toward ashen monochrome before the fog takes over.
    \\    float fLuma = dot(finalColor.rgb, vec3(0.299, 0.587, 0.114));
    \\    finalColor.rgb = mix(finalColor.rgb, vec3(fLuma), 0.10 + 0.25*(1.0 - core));
    \\    // FOG OF WAR: persistent exploration at this ground point (0 unseen .. 1 seen).
    \\    // The arena spans [-fogHalf.x, fogHalf.x] on X and [-fogHalf.y, fogHalf.y]
    \\    // on Z; map that onto the [0,1] fog map (componentwise).
    \\    vec2 fogUV = fragPosition.xz/(2.0*fogHalf) + 0.5;
    \\    float seen = texture(fogMap, fogUV).r;
    \\    // SEEN: a dim, cool, desaturated memory of the lit terrain -- drained toward
    \\    // grey, tinted cool, and darkened -- clearly distinct from the warm active disc.
    \\    // Unseen ground (seen = 0) collapses to black, so the world genuinely hides.
    \\    float luma = dot(memBase, vec3(0.299, 0.587, 0.114));
    \\    vec3 memory = mix(vec3(luma), memBase, 0.25)*vec3(0.50, 0.64, 0.62);
    \\    vec3 seenColor = memory*0.14*seen;
    \\    finalColor.rgb = mix(seenColor, finalColor.rgb, litDisc);
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

// FLOOR SENTINELS — scenemesh bakes these into texcoord u; sceneFS above branches on
// the hardcoded -1.5 / -0.5 thresholds. Owned HERE, next to the shader, with a pin so
// renumbering a sentinel can't silently repaint every ledge cap as the wrong material.
pub const FLAG_FLOOR: f32 = -1;
pub const FLAG_PAVE: f32 = -2;
comptime {
    std.debug.assert(FLAG_PAVE < -1.5 and FLAG_FLOOR > -1.5 and FLAG_FLOOR < -0.5);
}

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

/// Torch placement for this frame. `pos` is above the player; `groundRef` is the
/// walkable ground height under it (0 on flat floor, ledge height on a rampart) — the
/// overhead shadow camera aims at and sizes its cone against THAT plane, so raised
/// ground doesn't shrink the footprint. `radius` is the torch's reach before darkness.
pub const LightParams = struct {
    pos: rl.Vector3,
    radius: f32,
    groundRef: f32 = 0,
};

/// A moving fireball light. `pos` sits above the projectile (overhead, like the torch,
/// so its downward shadow map is well-oriented); `groundRef` as in LightParams;
/// `intensity` of 0 disables it entirely (no light/shadow, second depth pass skipped).
pub const FireParams = struct {
    pos: rl.Vector3,
    radius: f32,
    color: rl.Vector3,
    intensity: f32,
    groundRef: f32 = 0,
};

/// The fog-of-war memory layer sampled by the scene shader. `texId` is the GPU id of a
/// grayscale exploration map (fog.zig); `halfW`/`halfD` are the arena half-extents it
/// covers, so the shader can map a fragment's XZ into [0,1].
pub const FogParams = struct {
    texId: u32,
    halfW: f32,
    halfD: f32,
};

// The scene's `lightColor` uniform as an rgb + opaque-alpha vec4 — one construction
// shared by the init default and every per-area re-tint.
fn lightColorVec(rgb: [3]f32) [4]f32 {
    return .{ rgb[0], rgb[1], rgb[2], 1.0 };
}

pub const Torch = struct {
    shadowMap: rl.RenderTexture2D,
    fireMap: rl.RenderTexture2D,
    depthShader: rl.Shader,
    scene: rl.Shader,
    loc_lightPos: i32,
    loc_lightVP: i32,
    loc_lightRadius: i32,
    loc_lightColor: i32,
    loc_floorMats: i32,
    loc_fogHalf: i32,
    loc_fireVP: i32,
    loc_firePos: i32,
    loc_fireColor: i32,
    loc_fireRadius: i32,
    loc_fireIntensity: i32,
    lightVP: rl.Matrix = undefined,
    fireVP: rl.Matrix = undefined,
    fogTexId: u32 = 0, // fog-map GPU id to bind on SLOT_FOG; set by applyFogUniforms
    saved_near: @TypeOf(rl.gl.rlGetCullDistanceNear()) = 0,
    saved_far: @TypeOf(rl.gl.rlGetCullDistanceFar()) = 0,

    pub fn init() !Torch {
        const shadowMap = loadShadowmap(SHADOWMAP_RESOLUTION);
        errdefer rl.unloadRenderTexture(shadowMap);
        const fireMap = loadShadowmap(FIRE_SHADOWMAP_RESOLUTION);
        errdefer rl.unloadRenderTexture(fireMap);
        const depthShader = try rl.loadShaderFromMemory(depthVS, depthFS);
        errdefer rl.unloadShader(depthShader);
        const scene = try rl.loadShaderFromMemory(sceneVS, sceneFS);

        // Constant uniforms.
        const loc_lightColor = rl.getShaderLocation(scene, "lightColor");
        const lc = lightColorVec(DEFAULT_LIGHT);
        rl.setShaderValue(scene, loc_lightColor, &lc, .vec4);
        // Low, faintly sickly-green ambient: shadow pools stay near-black so the
        // torch reads as the only honest light in a diseased night.
        const amb = [4]f32{ 0.42, 0.50, 0.44, 1.0 };
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "ambient"), &amb, .vec4);
        const res: i32 = SHADOWMAP_RESOLUTION;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMapResolution"), &res, .int);
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "shadowMap"), &SLOT_SHADOW, .int);
        const fres: i32 = FIRE_SHADOWMAP_RESOLUTION;
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fireMapResolution"), &fres, .int);
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fireMap"), &SLOT_FIRE, .int);
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "fogMap"), &SLOT_FOG, .int);
        // Seed the floor set (dirt/grass/stone) so the shader is valid before the
        // first area applies its own via setFloorSet.
        const fm = [3]i32{ 0, 1, 2 };
        rl.setShaderValue(scene, rl.getShaderLocation(scene, "floorMats"), &fm, .ivec3);

        return .{
            .shadowMap = shadowMap,
            .fireMap = fireMap,
            .depthShader = depthShader,
            .scene = scene,
            .loc_lightPos = rl.getShaderLocation(scene, "lightPos"),
            .loc_lightVP = rl.getShaderLocation(scene, "lightVP"),
            .loc_lightRadius = rl.getShaderLocation(scene, "lightRadius"),
            .loc_lightColor = loc_lightColor,
            .loc_floorMats = rl.getShaderLocation(scene, "floorMats"),
            .loc_fogHalf = rl.getShaderLocation(scene, "fogHalf"),
            .loc_fireVP = rl.getShaderLocation(scene, "fireVP"),
            .loc_firePos = rl.getShaderLocation(scene, "firePos"),
            .loc_fireColor = rl.getShaderLocation(scene, "fireColor"),
            .loc_fireRadius = rl.getShaderLocation(scene, "fireRadius"),
            .loc_fireIntensity = rl.getShaderLocation(scene, "fireIntensity"),
            // Seed both matrices to identity: applyFireUniforms uploads fireVP every
            // frame, including before the first fireball sets it in a depth pass.
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

    // Shadow camera shared by torch and fireball: an overhead light looking straight
    // down, cone FOV sized to just cover `radius` on the LOCAL ground plane (groundY)
    // — sizing against absolute y=0 would shrink the disc on raised terrain. `up` must
    // not be parallel to the view direction or MatrixLookAt goes NaN.
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

    // Shared depth-pass scaffold: save clip planes, render into `map` from `cam`,
    // capture the light view-projection into `vpOut`, enter the depth shader. Caller
    // draws casters, then endDepthPass. Torch/fireball passes differ only in map + VP.
    fn beginDepthPass(self: *Torch, map: rl.RenderTexture2D, vpOut: *rl.Matrix, cam: rl.Camera3D) void {
        self.saved_near = rl.gl.rlGetCullDistanceNear();
        self.saved_far = rl.gl.rlGetCullDistanceFar();
        rl.gl.rlSetClipPlanes(SHADOW_CLIP_NEAR, SHADOW_CLIP_FAR);
        rl.beginTextureMode(map);
        rl.clearBackground(rl.Color.white);
        rl.beginMode3D(cam);
        vpOut.* = rl.math.matrixMultiply(rl.gl.rlGetMatrixModelview(), rl.gl.rlGetMatrixProjection());
        rl.beginShaderMode(self.depthShader);
    }

    fn endDepthPass(self: *Torch) void {
        rl.endShaderMode();
        rl.endMode3D();
        rl.endTextureMode();
        rl.gl.rlSetClipPlanes(self.saved_near, self.saved_far);
    }

    // Torch depth pass: call this, draw casters, then endShadowPass().
    pub fn beginShadowPass(self: *Torch, lp: LightParams) void {
        self.beginDepthPass(self.shadowMap, &self.lightVP, overheadCamera(lp.pos, lp.radius, lp.groundRef));
    }

    pub fn endShadowPass(self: *Torch) void {
        self.endDepthPass();
    }

    // Fireball depth pass: only run when a fireball is live (fp.intensity>0), into the
    // smaller fireMap from the fireball's overhead camera.
    pub fn beginFireShadowPass(self: *Torch, fp: FireParams) void {
        self.beginDepthPass(self.fireMap, &self.fireVP, overheadCamera(fp.pos, fp.radius, fp.groundRef));
    }

    pub fn endFireShadowPass(self: *Torch) void {
        self.endDepthPass();
    }

    // Main-pass uniforms: call after beginDrawing()+clear and BEFORE beginMode3D(cam).
    pub fn applyUniforms(self: *Torch, lp: LightParams) void {
        const p = [3]f32{ lp.pos.x, lp.pos.y, lp.pos.z };
        rl.setShaderValue(self.scene, self.loc_lightPos, &p, .vec3);
        const r = lp.radius;
        rl.setShaderValue(self.scene, self.loc_lightRadius, &r, .float);
        rl.setShaderValueMatrix(self.scene, self.loc_lightVP, self.lightVP);
    }

    // Fireball light uniforms. Pass intensity 0 when no fireball is live; the shader
    // then skips the whole fireball term.
    pub fn applyFireUniforms(self: *Torch, fp: FireParams) void {
        // Shader skips the fireball term at intensity 0, so on the common no-fireball
        // frame only intensity matters — uploading pos/color/radius/VP would be four
        // wasted setShaderValue calls.
        const i = fp.intensity;
        rl.setShaderValue(self.scene, self.loc_fireIntensity, &i, .float);
        if (i <= 0) return;
        const p = [3]f32{ fp.pos.x, fp.pos.y, fp.pos.z };
        rl.setShaderValue(self.scene, self.loc_firePos, &p, .vec3);
        const c = [3]f32{ fp.color.x, fp.color.y, fp.color.z };
        rl.setShaderValue(self.scene, self.loc_fireColor, &c, .vec3);
        const r = fp.radius;
        rl.setShaderValue(self.scene, self.loc_fireRadius, &r, .float);
        rl.setShaderValueMatrix(self.scene, self.loc_fireVP, self.fireVP);
    }

    // Per-area torch personality: re-tint the light per area (warmer, paler, sicklier)
    // so one pipeline gives every floor its own night. Once per area transition, not
    // per frame.
    pub fn setLightColor(self: *Torch, rgb: [3]f32) void {
        const lc = lightColorVec(rgb);
        rl.setShaderValue(self.scene, self.loc_lightColor, &lc, .vec4);
    }

    // The area's floor-material set (see world.FloorMat / the shader's matAlbedo).
    // Once per area transition, like setLightColor.
    pub fn setFloorSet(self: *Torch, fs: world.FloorSet) void {
        const m = [3]i32{ @intFromEnum(fs[0]), @intFromEnum(fs[1]), @intFromEnum(fs[2]) };
        rl.setShaderValue(self.scene, self.loc_floorMats, &m, .ivec3);
    }

    // Fog-of-war uniforms. Stash the map's GPU id for beginScene to bind on SLOT_FOG,
    // and upload the arena half-extents so the shader can map fragments into the map.
    pub fn applyFogUniforms(self: *Torch, fog: FogParams) void {
        self.fogTexId = fog.texId;
        const h = [2]f32{ fog.halfW, fog.halfD };
        rl.setShaderValue(self.scene, self.loc_fogHalf, &h, .vec2);
    }

    // Wrap lit geometry between beginScene()/endScene(), inside beginMode3D(cam).
    pub fn beginScene(self: *Torch) void {
        rl.beginShaderMode(self.scene);
        rl.gl.rlActiveTextureSlot(SLOT_SHADOW);
        rl.gl.rlEnableTexture(@intCast(self.shadowMap.depth.id));
        rl.gl.rlActiveTextureSlot(SLOT_FIRE);
        rl.gl.rlEnableTexture(@intCast(self.fireMap.depth.id));
        rl.gl.rlActiveTextureSlot(SLOT_FOG);
        rl.gl.rlEnableTexture(self.fogTexId);
    }

    pub fn endScene(self: *Torch) void {
        _ = self;
        rl.endShaderMode();
    }
};
