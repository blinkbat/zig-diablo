const rl = @import("raylib");
const mathx = @import("mathx.zig");
const stats = @import("stats.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;

// What a projectile IS — drives its look (drawProjectiles), trail, and impact. FromPlayer
// still says whose it is (who it can hit); Kind says what it does on the way and on impact.
pub const Kind = enum { firebolt, arrow, ice_shard, knife, flask };

pub const Projectile = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Vel: rl.Vector3 = mathx.zero3,
    // Typed damage packet (firebolt = fire, arrow/knife = physical, ice = cold); hit-site
    // mitigation applies armor/resists per component. A flask carries NO direct damage —
    // it bursts into a cloud, so its DoT rides `Payload` instead.
    Damage: stats.Damage = .{},
    Kind: Kind = .arrow,
    Radius: f32 = 0,
    Life: f32 = 0,
    FromPlayer: bool = false,
    Payload: f32 = 0, // flask: dps of the poison cloud it bursts into
};

// Flight speeds, public so shooters can compute yVel to land on a target at a
// different terrain height (yVel = dY / flight time).
pub const fireboltSpeed = 19.0;
pub const arrowSpeed = 13.0;
pub const iceShardSpeed = 17.0;
pub const knifeSpeed = 24.0; // the fastest thing you can throw
pub const flaskSpeed = 12.0; // a heavy lob

// Muzzle height above the shooter's ground point. The SAME offset feeds the spawn
// position below AND the caller's aimYVel (game.zig), so the arc starts from the
// exact height the bolt leaves — change here and both move together.
pub const fireboltMuzzleDY = 1.1;
pub const arrowMuzzleDY = 1.2;
pub const handMuzzleDY = 1.15; // ice shard / knife / flask all leave the hero's hand

// Firebolt core orange. Public so the bolt body and its spark trail (game.zig)
// read as one flame.
pub const fireboltColor = rgba(255, 150, 40, 255);
pub const iceShardColor = rgba(150, 210, 245, 255); // pale glacial blue
pub const toxicColor = rgba(170, 220, 90, 255); // poison green (matches the gas cloud)

// White-hot heart of any flame — firebolt core and torch inner tongue share it.
pub const flameHeartColor = rgba(255, 246, 205, 255);

// The one spawn/aim wiring: a muzzle point `muzzleDY` above the shooter's ground
// point, launched horizontally at `speed` carrying the caller's `yVel` slope. Each
// newX below fills only the constants that make it that projectile (Damage/Payload
// are set by the caller). Keeps every bolt's muzzle+velocity formula in one place.
fn spawn(kind: Kind, from: rl.Vector3, dir: rl.Vector3, speed: f32, muzzleDY: f32, yVel: f32, radius: f32, life: f32, fromPlayer: bool) Projectile {
    return .{
        .Pos = v3(from.x, from.y + muzzleDY, from.z),
        .Vel = v3(dir.x * speed, yVel, dir.z * speed),
        .Kind = kind,
        .Radius = radius,
        .Life = life,
        .FromPlayer = fromPlayer,
    };
}

// Player's right-click spell. `from` is the caster's ground point; `yVel` slopes
// the flight toward a raised or sunken target.
pub fn newFirebolt(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    var pr = spawn(.firebolt, from, dir, fireboltSpeed, fireboltMuzzleDY, yVel, 0.45, 2.0, true);
    pr.Damage = dmg;
    return pr;
}

// Ice Shard: cold single-target bolt; the caller applies the chill on impact.
pub fn newIceShard(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    var pr = spawn(.ice_shard, from, dir, iceShardSpeed, handMuzzleDY, yVel, 0.4, 2.0, true);
    pr.Damage = dmg;
    return pr;
}

// Throwing Knife: fast, cheap physical dart.
pub fn newKnife(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    var pr = spawn(.knife, from, dir, knifeSpeed, handMuzzleDY, yVel, 0.28, 1.6, true);
    pr.Damage = dmg;
    return pr;
}

// Toxic Flask: a lobbed vial that bursts into a poison cloud on impact. No direct
// damage — `dps` is the cloud's damage-over-time, read by the impact handler.
pub fn newFlask(from: rl.Vector3, dir: rl.Vector3, dps: f32, yVel: f32) Projectile {
    var pr = spawn(.flask, from, dir, flaskSpeed, handMuzzleDY, yVel, 0.3, 1.5, true);
    pr.Payload = dps;
    return pr;
}

// newArrow is the skeleton archer's attack.
pub fn newArrow(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, yVel: f32) Projectile {
    var pr = spawn(.arrow, from, dir, arrowSpeed, arrowMuzzleDY, yVel, 0.35, 2.5, false);
    pr.Damage = dmg;
    return pr;
}
