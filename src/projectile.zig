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

// newFirebolt is the player's right-click spell.
pub fn newFirebolt(from: rl.Vector3, dir: rl.Vector3, dmg: f32) Projectile {
    const speed = 19.0;
    return .{
        .Pos = v3(from.x, 1.1, from.z),
        .Vel = v3(dir.x * speed, 0, dir.z * speed),
        .Damage = dmg,
        .Radius = 0.45,
        .Life = 2.0,
        .FromPlayer = true,
        .Color = rgba(255, 150, 40, 255),
    };
}

// newArrow is the skeleton archer's attack.
pub fn newArrow(from: rl.Vector3, dir: rl.Vector3, dmg: f32) Projectile {
    const speed = 13.0;
    return .{
        .Pos = v3(from.x, 1.2, from.z),
        .Vel = v3(dir.x * speed, 0, dir.z * speed),
        .Damage = dmg,
        .Radius = 0.35,
        .Life = 2.5,
        .FromPlayer = false,
        .Color = rgba(230, 230, 210, 255),
    };
}
