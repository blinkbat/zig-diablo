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

// Capacity of a monster's inline name buffer. The boss name is copied in from the
// map's `boss:` field, so map.zig sizes that StrBuf to this same constant — grow
// one and the other follows instead of silently truncating boss names.
pub const NAME_CAP = 48;

// How long (seconds) a slain monster takes to fade out.
pub const monster_death_fade = 0.55;

// How long (seconds) a struck monster flashes white. Owned here (like the death
// fade) rather than as a bare literal in game.zig's combat code.
pub const monster_hitflash = 0.12;

// Kinds whose strike telegraph is carried ENTIRELY by the body animation (the
// pib's cocked knife, the zombie's overhead raise, the skeleton's drawn bow):
// no red ground marking or beam is drawn for them, so their windup poses must
// stay unmistakable.
pub fn animTelegraph(kind: MonsterKind) bool {
    return kind == .fallen or kind == .zombie or kind == .skeleton;
}

// Pib pack panic (Diablo's Fallen): watching any packmate die within this range
// sends a pib scattering for a few seconds. Aggro survives the panic, so they
// regroup and come right back — cowardice, not retreat.
pub const flee_trigger_radius = 9.0;
pub const flee_time_min = 2.2;
pub const flee_time_rand = 1.6;

// Monster is a hostile entity. AI is a simple wander/aggro/chase/attack loop.
pub const Monster = struct {
    id: i32 = 0,
    Kind: MonsterKind = .fallen,
    // Name is stored INLINE, not as a slice: a boss name sliced from the map's
    // `boss:` field would dangle whenever the struct that owns the map moves
    // (see the StrBuf note in map.zig). Cap shared with Map.boss via NAME_CAP.
    nameBuf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    nameLen: u8 = 0,
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
    swing: f32 = 0, // >0 while the strike arc plays out; the hit lands at its midpoint
    swingTime: f32 = 0, // 0 = no follow-through anim: the hit resolves at windup end
    fleeTimer: f32 = 0, // >0 while scattering in panic (pibs; see flee_* above)
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

    pub fn name(m: *const Monster) []const u8 {
        return m.nameBuf[0..m.nameLen];
    }

    pub fn setName(m: *Monster, s: []const u8) void {
        const n = @min(s.len, m.nameBuf.len);
        @memcpy(m.nameBuf[0..n], s[0..n]);
        m.nameLen = @intCast(n);
    }

    /// Telegraph progress 0→1 as a committed strike winds up (0 when not winding
    /// up). Shared by the body pose, the flashing tint, and the FX ring/beam so the
    /// drawn telegraph and the strike timing can never drift apart.
    pub fn windupProgress(m: *const Monster) f32 {
        if (m.windup <= 0 or m.windupTime <= 0) return 0;
        return 1 - m.windup / m.windupTime;
    }

    /// Strike-arc progress 0→1 as the committed blow sweeps through (0 when idle).
    /// Shared by the body pose and the FX pass (blade trail), and it's what the
    /// damage timing reads too — the hit lands where the swing visibly is.
    pub fn swingProgress(m: *const Monster) f32 {
        if (m.swing <= 0 or m.swingTime <= 0) return 0;
        return 1 - m.swing / m.swingTime;
    }

    pub fn fleeing(m: *const Monster) bool {
        return m.fleeTimer > 0;
    }
};

// makeMonster builds a monster of the given kind, scaled by difficulty tier.
pub fn makeMonster(kind: MonsterKind, tier: i32, rng: *Rng, pos: rl.Vector3) Monster {
    _ = rng; // parity with Go signature; kind stats are deterministic
    const t: f32 = @floatFromInt(tier);
    var m = Monster{ .Kind = kind, .Pos = pos, .Facing = v3(0, 0, 1) };
    switch (kind) {
        .fallen => {
            m.setName("Pib"); // the knife pigs (gf-certified)
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
            // The knife arc IS the telegraph (no ground ring): windup cocks the
            // blade back, then the swing whips it through — quick, but the cock
            // before it is the readable beat.
            m.windupTime = 0.5;
            m.swingTime = 0.22;
        },
        .zombie => {
            m.setName("Zombie");
            // A lumbering wall: too slow to catch anyone paying attention, too
            // tanky to ignore, and its overhead slam ruins whoever stands in it.
            m.MaxHP = 115 + t * 34;
            m.Speed = 1.35 + t * 0.1;
            m.Radius = 0.6;
            m.Height = 2.0;
            m.Color = rgba(96, 120, 78, 255);
            m.MinDmg = 30 + t * 5;
            m.MaxDmg = 46 + t * 7;
            m.XP = 22 + tier * 8;
            m.GoldDrop = 9 + tier * 5;
            m.atkRange = 2.0;
            m.sightRange = 12;
            m.atkRate = 3.4;
            // Long overhead raise, then a near-instant drop: the raise is the whole
            // telegraph (and must give even a walking player time to leave); the
            // slam itself is a guillotine.
            m.windupTime = 1.15;
            m.swingTime = 0.18;
        },
        .skeleton => {
            m.setName("Skeleton Archer");
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
            // The draw IS the telegraph (no aiming beam): bow tracking you, string
            // coming back, arrowhead heating — long enough to read and sidestep.
            m.windupTime = 0.75;
        },
        .brute => {
            m.setName("Brute");
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
pub fn makeBoss(tier: i32, bossName: []const u8, rng: *Rng, pos: rl.Vector3) Monster {
    var m = makeMonster(.brute, tier, rng, pos);
    m.boss = true;
    m.setName(bossName); // copied, not aliased: the caller's map may move
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
