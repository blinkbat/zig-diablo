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

// Muzzle height above the shooter's ground point. Feeds both the spawn position and
// the arc solve inside `spawn`, so the flight starts from the exact height the bolt
// leaves — speed and muzzle never part company at a call site.
pub const fireboltMuzzleDY = 1.1;
pub const arrowMuzzleDY = 1.2;
pub const handMuzzleDY = 1.15; // ice shard / knife / flask all leave the hero's hand

// Firebolt core orange. Public so the bolt body and its spark trail (game.zig)
// read as one flame.
pub const fireboltColor = rgba(255, 150, 40, 255);
pub const iceShardColor = rgba(150, 210, 245, 255); // pale glacial blue
pub const toxicColor = rgba(170, 220, 90, 255); // poison green: flask body/burst + HUD chip (the cloud runs its own GAS_ shades)

// White-hot heart of any flame — the firebolt core and the HUD flame glyph share it.
pub const flameHeartColor = rgba(255, 246, 205, 255);

// Vertical velocity carrying a shot from muzzle to target height over its flight (a
// bolt raining off a rampart, an arrow climbing up). Clamped so point-blank aims
// can't become mortars.
fn aimYVel(fromY: f32, toY: f32, distH: f32, speed: f32) f32 {
    const ft = mathx.maxF(distH, 2.0) / speed;
    return mathx.clampF((toY - fromY) / ft, -9.0, 9.0);
}

// The one spawn/aim wiring: a muzzle point `muzzleDY` above the shooter's ground
// point, launched at `speed` with the vertical arc solved HERE toward (`targetY`,
// `distH`) — callers can't mispair a speed with another bolt's muzzle. Each newX
// below fills only the constants that make it that projectile (Damage/Payload are
// set by the caller).
fn spawn(kind: Kind, from: rl.Vector3, dir: rl.Vector3, speed: f32, muzzleDY: f32, targetY: f32, distH: f32, radius: f32, life: f32, fromPlayer: bool) Projectile {
    const muzzleY = from.y + muzzleDY;
    return .{
        .Pos = v3(from.x, muzzleY, from.z),
        .Vel = v3(dir.x * speed, aimYVel(muzzleY, targetY, distH, speed), dir.z * speed),
        .Kind = kind,
        .Radius = radius,
        .Life = life,
        .FromPlayer = fromPlayer,
    };
}

// Player's right-click spell. `from` is the caster's ground point; the flight slopes
// toward `targetY` over `distH` (a raised or sunken aim point).
pub fn newFirebolt(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, targetY: f32, distH: f32) Projectile {
    var pr = spawn(.firebolt, from, dir, fireboltSpeed, fireboltMuzzleDY, targetY, distH, 0.45, 2.0, true);
    pr.Damage = dmg;
    return pr;
}

// Ice Shard: cold single-target bolt; the caller applies the chill on impact.
pub fn newIceShard(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, targetY: f32, distH: f32) Projectile {
    var pr = spawn(.ice_shard, from, dir, iceShardSpeed, handMuzzleDY, targetY, distH, 0.4, 2.0, true);
    pr.Damage = dmg;
    return pr;
}

// Throwing Knife: fast, cheap physical dart.
pub fn newKnife(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, targetY: f32, distH: f32) Projectile {
    var pr = spawn(.knife, from, dir, knifeSpeed, handMuzzleDY, targetY, distH, 0.28, 1.6, true);
    pr.Damage = dmg;
    return pr;
}

// Toxic Flask: a lobbed vial that bursts into a poison cloud on impact. No direct
// damage — `dps` is the cloud's damage-over-time, read by the impact handler.
pub fn newFlask(from: rl.Vector3, dir: rl.Vector3, dps: f32, targetY: f32, distH: f32) Projectile {
    var pr = spawn(.flask, from, dir, flaskSpeed, handMuzzleDY, targetY, distH, 0.3, 1.5, true);
    pr.Payload = dps;
    return pr;
}

// newArrow is the skeleton archer's attack.
pub fn newArrow(from: rl.Vector3, dir: rl.Vector3, dmg: stats.Damage, targetY: f32, distH: f32) Projectile {
    var pr = spawn(.arrow, from, dir, arrowSpeed, arrowMuzzleDY, targetY, distH, 0.35, 2.5, false);
    pr.Damage = dmg;
    return pr;
}
