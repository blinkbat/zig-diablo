const rl = @import("raylib");
const mathx = @import("mathx.zig");
const stats = @import("stats.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

pub const Projectile = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Vel: rl.Vector3 = mathx.zero3,
    // Typed damage packet (firebolt = fire, arrow = physical); hit-site mitigation
    // applies armor/resists per component.
    Damage: stats.Damage = .{},
    Radius: f32 = 0,
    Life: f32 = 0,
    FromPlayer: bool = false,
};

// Flight speeds, public so shooters can compute yVel to land on a target at a
// different terrain height (yVel = dY / flight time).
pub const fireboltSpeed = 19.0;
pub const arrowSpeed = 13.0;

// Muzzle height above the shooter's ground point. The SAME offset feeds the spawn
// position below AND the caller's aimYVel (game.zig), so the arc starts from the
// exact height the bolt leaves — change here and both move together.
pub const fireboltMuzzleDY = 1.1;
pub const arrowMuzzleDY = 1.2;

// Firebolt core orange. Public so the bolt body and its spark trail (game.zig)
// read as one flame.
pub const fireboltColor = rgba(255, 150, 40, 255);

// White-hot heart of any flame — firebolt core and torch inner tongue share it.
pub const flameHeartColor = rgba(255, 246, 205, 255);

// Player's right-click spell. `from` is the caster's ground point; `yVel` slopes
// the flight toward a raised or sunken target.
pub fn newFirebolt(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    return .{
        .Pos = v3(from.x, from.y + fireboltMuzzleDY, from.z),
        .Vel = v3(dir.x * fireboltSpeed, yVel, dir.z * fireboltSpeed),
        .Damage = dmg,
        .Radius = 0.45,
        .Life = 2.0,
        .FromPlayer = true,
    };
}

// newArrow is the skeleton archer's attack.
pub fn newArrow(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    return .{
        .Pos = v3(from.x, from.y + arrowMuzzleDY, from.z),
        .Vel = v3(dir.x * arrowSpeed, yVel, dir.z * arrowSpeed),
        .Damage = dmg,
        .Radius = 0.35,
        .Life = 2.5,
        .FromPlayer = false,
    };
}
