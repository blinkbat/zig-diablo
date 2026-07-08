const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const clampF = mathx.clampF;

// camRig holds the follow-camera state: a fixed high three-quarter iso angle
// behind the player, zoomable.
pub const CamRig = struct {
    cam: rl.Camera3D,
    zoom: f32, // 1 = default framing; larger = closer

    /// Point the camera at target with the fixed iso offset (scaled by zoom),
    /// smoothed toward it so the view glides.
    pub fn follow(c: *CamRig, target: rl.Vector3, dt: f32) void {
        const off = v3(0, 30 / c.zoom, 22 / c.zoom);
        const want = v3(target.x + off.x, off.y, target.z + off.z);
        const a = clampF(dt * 8, 0, 1);
        c.cam.position = c.cam.position.lerp(want, a);
        const lookAt = v3(target.x, target.y + 1.0, target.z);
        c.cam.target = c.cam.target.lerp(lookAt, a);
    }

    pub fn snap(c: *CamRig, target: rl.Vector3) void {
        const off = v3(0, 30 / c.zoom, 22 / c.zoom);
        c.cam.position = v3(target.x + off.x, off.y, target.z + off.z);
        c.cam.target = v3(target.x, target.y + 1.0, target.z);
    }

    pub fn addZoom(c: *CamRig, delta: f32) void {
        c.zoom = clampF(c.zoom + delta * 0.12, 0.6, 2.2);
    }
};

pub fn newCamRig() CamRig {
    return .{
        .cam = .{
            .position = mathx.zero3,
            .target = mathx.zero3,
            .up = v3(0, 1, 0),
            .fovy = 50,
            .projection = .perspective,
        },
        .zoom = 1.4, // start pulled in so the lit detail reads
    };
}
