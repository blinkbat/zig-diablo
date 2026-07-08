const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");

const GameState = state.GameState;

// Point-light lighting + cast shadows — the EXACT technique from the working demo
// (raylib's official shadowmap example, ported). The torch is the point light;
// every surface is shaded by NdotL from it and shadowed via a depth map. The only
// change from the demo is object color: immediate-mode draws carry color in the
// vertex color (fragColor), so the shader multiplies by that instead of colDiffuse.

pub const fogColor = mathx.rgba(12, 12, 16, 255); // window clear color

// Vision radius (fog-of-war keys off this — kept as a plain gameplay constant).
pub const torchBaseRadius = 32.0;

// The torch point light sits at the hero + this offset (up + toward NE), so shadows
// fall toward the camera and have length. Shared by the light shader and the shadow
// camera so the lit direction and the shadows agree.
pub const torchLightOffset = [3]f32{ 3.0, 16.0, -4.0 };

pub const lightVS =
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

pub const lightFS =
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
    \\    finalColor = (texelColor*((fragColor + vec4(specular, 1.0))*vec4(lightDot, 1.0)));
    \\    vec4 fragPosLightSpace = lightVP*vec4(fragPosition, 1);
    \\    fragPosLightSpace.xyz /= fragPosLightSpace.w;
    \\    fragPosLightSpace.xyz = (fragPosLightSpace.xyz + 1.0)/2.0;
    \\    vec2 sampleCoords = fragPosLightSpace.xy;
    \\    float curDepth = fragPosLightSpace.z;
    \\    // Only shadow fragments INSIDE the light's frustum. The game ground is far
    \\    // larger than that frustum; outside it there is no depth data, and sampling
    \\    // the clamped edge invents huge spurious shadows (the bands / dark areas).
    \\    // The demo never hit this because its whole scene fit inside the light.
    \\    if (curDepth <= 1.0 && sampleCoords.x >= 0.0 && sampleCoords.x <= 1.0 && sampleCoords.y >= 0.0 && sampleCoords.y <= 1.0) {
    \\        float bias = max(0.0025*(1.0 - dot(normal, l)), 0.0007);
    \\        int shadowCounter = 0;
    \\        const int numSamples = 9;
    \\        vec2 texelSize = vec2(1.0/float(shadowMapResolution));
    \\        for (int x = -1; x <= 1; x++) {
    \\            for (int y = -1; y <= 1; y++) {
    \\                float sampleDepth = texture(shadowMap, sampleCoords + texelSize*vec2(x, y)).r;
    \\                if (curDepth - bias > sampleDepth) shadowCounter++;
    \\            }
    \\        }
    \\        finalColor = mix(finalColor, vec4(0, 0, 0, 1), float(shadowCounter)/float(numSamples));
    \\    }
    \\    finalColor += texelColor*(ambient/10.0)*fragColor;
    \\    finalColor = pow(finalColor, vec4(1.0/2.2));
    \\}
;

pub fn initLighting(g: *GameState) void {
    const s = rl.loadShaderFromMemory(lightVS, lightFS) catch {
        g.lightingOn = false;
        g.lightLoaded = false;
        return;
    };
    if (!rl.isShaderValid(s)) {
        g.lightingOn = false;
        g.lightLoaded = false;
        return;
    }
    g.lightShader = s;
    g.loc_lightPos = rl.getShaderLocation(s, "lightPos");
    g.loc_lightColor = rl.getShaderLocation(s, "lightColor");
    g.loc_ambient = rl.getShaderLocation(s, "ambient");
    g.loc_viewPos = rl.getShaderLocation(s, "viewPos");
    g.loc_lightVP = rl.getShaderLocation(s, "lightVP");
    g.loc_shadowMap = rl.getShaderLocation(s, "shadowMap");
    g.loc_res = rl.getShaderLocation(s, "shadowMapResolution");
    const lc = [4]f32{ 1.0, 0.95, 0.82, 1.0 }; // warm torch tint
    rl.setShaderValue(s, g.loc_lightColor, &lc, .vec4);
    const amb = [4]f32{ 0.55, 0.55, 0.65, 1.0 };
    rl.setShaderValue(s, g.loc_ambient, &amb, .vec4);
    g.lightLoaded = true;
    g.lightingOn = true;
}

pub fn unloadLighting(g: *GameState) void {
    if (g.lightLoaded) {
        rl.unloadShader(g.lightShader);
        g.lightLoaded = false;
    }
}

// Push per-frame uniforms: the torch's world position (light source), the view
// position (for specular), and the light view-projection captured in the depth pass.
pub fn applyLightUniforms(g: *GameState, cam: rl.Camera3D) void {
    const lp = [3]f32{
        g.player.Pos.x + torchLightOffset[0],
        g.player.Pos.y + torchLightOffset[1],
        g.player.Pos.z + torchLightOffset[2],
    };
    rl.setShaderValue(g.lightShader, g.loc_lightPos, &lp, .vec3);
    const vp = [3]f32{ cam.position.x, cam.position.y, cam.position.z };
    rl.setShaderValue(g.lightShader, g.loc_viewPos, &vp, .vec3);
    rl.setShaderValueMatrix(g.lightShader, g.loc_lightVP, g.lightVP);
}

// surf/glow are now passthroughs — the shader does all lighting. (Kept so the many
// render call sites are unchanged.) drawShadow is a no-op — the shadow map casts
// real shadows.
pub fn surf(g: *GameState, c: rl.Color, p: rl.Vector3) rl.Color {
    _ = g;
    _ = p;
    return c;
}
pub fn glow(g: *GameState, c: rl.Color, p: rl.Vector3) rl.Color {
    _ = g;
    _ = p;
    return c;
}
pub fn drawShadow(g: *GameState, p: rl.Vector3, radius: f32) void {
    _ = g;
    _ = p;
    _ = radius;
}
