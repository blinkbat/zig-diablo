const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

pub const Projectile = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Vel: rl.Vector3 = mathx.zero3,
    Damage: f32 = 0,
    Radius: f32 = 0,
    Life: f32 = 0,
    FromPlayer: bool = false,
    Color: rl.Color = rgba(255, 255, 255, 255),
};

// Flight speeds, public so shooters can compute the vertical velocity that lands
// a shot on a target at a different terrain height (yVel = dY / flight time).
pub const fireboltSpeed = 19.0;
pub const arrowSpeed = 13.0;

// newFirebolt is the player's right-click spell. `from` carries the caster's
// ground height; `yVel` slopes the flight toward a raised or sunken target.
pub fn newFirebolt(from: rl.Vector3, dir: rl.Vector3, dmg: f32, yVel: f32) Projectile {
    return .{
        .Pos = v3(from.x, from.y + 1.1, from.z),
        .Vel = v3(dir.x * fireboltSpeed, yVel, dir.z * fireboltSpeed),
        .Damage = dmg,
        .Radius = 0.45,
        .Life = 2.0,
        .FromPlayer = true,
        .Color = rgba(255, 150, 40, 255),
    };
}

// newArrow is the skeleton archer's attack.
pub fn newArrow(from: rl.Vector3, dir: rl.Vector3, dmg: f32, yVel: f32) Projectile {
    return .{
        .Pos = v3(from.x, from.y + 1.2, from.z),
        .Vel = v3(dir.x * arrowSpeed, yVel, dir.z * arrowSpeed),
        .Damage = dmg,
        .Radius = 0.35,
        .Life = 2.5,
        .FromPlayer = false,
        .Color = rgba(230, 230, 210, 255),
    };
}
