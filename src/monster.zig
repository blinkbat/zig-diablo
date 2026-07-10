const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const Rng = mathx.Rng;

pub const MonsterKind = enum(u8) {
    fallen, // fast, weak melee imp
    zombie, // slow, tanky melee
    skeleton, // ranged archer
    brute, // big, hard-hitting melee
};

// How long (seconds) a slain monster takes to fade out.
pub const monster_death_fade = 0.55;

// How long (seconds) a struck monster flashes white. Owned here (like the death
// fade) rather than as a bare literal in game.zig's combat code.
pub const monster_hitflash = 0.12;

// Monster is a hostile entity. AI is a simple wander/aggro/chase/attack loop.
pub const Monster = struct {
    id: i32 = 0,
    Kind: MonsterKind = .fallen,
    Name: []const u8 = "",
    Pos: rl.Vector3 = mathx.zero3,
    Facing: rl.Vector3 = mathx.zero3,
    HP: f32 = 0,
    MaxHP: f32 = 0,
    Speed: f32 = 0,
    Radius: f32 = 0,
    Height: f32 = 0,
    Color: rl.Color = rgba(255, 255, 255, 255),
    MinDmg: f32 = 0,
    MaxDmg: f32 = 0,
    XP: i32 = 0,
    GoldDrop: i32 = 0,
    Ranged: bool = false,
    atkRange: f32 = 0,
    sightRange: f32 = 0,
    atkRate: f32 = 0,
    atkCD: f32 = 0,
    windup: f32 = 0, // >0 while telegraphing a committed strike
    windupTime: f32 = 0,
    aggro: bool = false,
    hitFlash: f32 = 0,
    wanderTimer: f32 = 0,
    wanderDir: rl.Vector3 = mathx.zero3,
    bob: f32 = 0,
    deathTimer: f32 = 0, // >0 while playing the death fade, then removed
    dying: bool = false,
    boss: bool = false,

    pub fn alive(m: *const Monster) bool {
        return m.HP > 0 and !m.dying;
    }

    /// Telegraph progress 0→1 as a committed strike winds up (0 when not winding
    /// up). Shared by the body pose, the flashing tint, and the FX ring/beam so the
    /// drawn telegraph and the strike timing can never drift apart.
    pub fn windupProgress(m: *const Monster) f32 {
        if (m.windup <= 0 or m.windupTime <= 0) return 0;
        return 1 - m.windup / m.windupTime;
    }
};

// makeMonster builds a monster of the given kind, scaled by difficulty tier.
pub fn makeMonster(kind: MonsterKind, tier: i32, rng: *Rng, pos: rl.Vector3) Monster {
    _ = rng; // parity with Go signature; kind stats are deterministic
    const t: f32 = @floatFromInt(tier);
    var m = Monster{ .Kind = kind, .Pos = pos, .Facing = v3(0, 0, 1) };
    switch (kind) {
        .fallen => {
            m.Name = "Pib"; // the knife pigs (gf-certified)
            m.MaxHP = 30 + t * 11;
            m.Speed = 3.8 + t * 0.2;
            m.Radius = 0.45;
            m.Height = 1.4;
            m.Color = rgba(170, 60, 50, 255);
            m.MinDmg = 10 + t * 2;
            m.MaxDmg = 16 + t * 3;
            m.XP = 9 + tier * 4;
            m.GoldDrop = 4 + tier * 3;
            m.atkRange = 1.7;
            m.sightRange = 14;
            m.atkRate = 1.6;
            m.windupTime = 0.45;
        },
        .zombie => {
            m.Name = "Zombie";
            m.MaxHP = 70 + t * 24;
            m.Speed = 2.0 + t * 0.15;
            m.Radius = 0.6;
            m.Height = 2.0;
            m.Color = rgba(96, 120, 78, 255);
            m.MinDmg = 18 + t * 3;
            m.MaxDmg = 28 + t * 4;
            m.XP = 16 + tier * 6;
            m.GoldDrop = 7 + tier * 4;
            m.atkRange = 2.0;
            m.sightRange = 12;
            m.atkRate = 2.2;
            m.windupTime = 0.7;
        },
        .skeleton => {
            m.Name = "Skeleton Archer";
            m.MaxHP = 42 + t * 15;
            m.Speed = 3.0 + t * 0.2;
            m.Radius = 0.5;
            m.Height = 1.9;
            m.Color = rgba(220, 220, 205, 255);
            m.MinDmg = 12 + t * 2.5;
            m.MaxDmg = 20 + t * 3;
            m.Ranged = true;
            m.XP = 17 + tier * 6;
            m.GoldDrop = 9 + tier * 5;
            m.atkRange = 17;
            m.sightRange = 22;
            m.atkRate = 2.2;
            m.windupTime = 0.6;
        },
        .brute => {
            m.Name = "Brute";
            m.MaxHP = 170 + t * 60;
            m.Speed = 2.4 + t * 0.2;
            m.Radius = 1.0;
            m.Height = 3.0;
            m.Color = rgba(150, 70, 120, 255);
            m.MinDmg = 35 + t * 5;
            m.MaxDmg = 55 + t * 7;
            m.XP = 48 + tier * 16;
            m.GoldDrop = 30 + tier * 12;
            m.atkRange = 2.6;
            m.sightRange = 16;
            m.atkRate = 2.6;
            m.windupTime = 0.85;
        },
    }
    m.HP = m.MaxHP;
    return m;
}

// makeBoss promotes a brute into the area's champion. The name is supplied by the
// caller (the map's `boss:` field), so there's no parallel tier->name table to
// keep in lockstep.
pub fn makeBoss(tier: i32, name: []const u8, rng: *Rng, pos: rl.Vector3) Monster {
    var m = makeMonster(.brute, tier, rng, pos);
    m.boss = true;
    m.Name = name;
    m.MaxHP = m.MaxHP * 2.4 + 120;
    m.HP = m.MaxHP;
    m.MinDmg *= 1.4;
    m.MaxDmg *= 1.4;
    m.XP = m.XP * 4 + 120;
    m.GoldDrop = m.GoldDrop * 4 + 80;
    m.Radius = 1.3;
    m.Height = 3.8;
    m.Color = rgba(190, 50, 60, 255);
    m.sightRange = 26;
    return m;
}
