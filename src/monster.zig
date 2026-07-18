const rl = @import("raylib");
const mathx = @import("mathx.zig");
const stats = @import("stats.zig");

const v3 = mathx.v3;
const rgba = mathx.rgba;
const Rng = mathx.Rng;
const maxF = mathx.maxF;

pub const MonsterKind = enum(u8) {
    fallen, // fast, weak melee imp
    zombie, // slow, tanky melee
    skeleton, // ranged archer
    brute, // big, hard-hitting melee
};

// Inline name-buffer cap; shared with Map.boss (map.zig sizes its StrBuf to this)
// so boss names copy in without truncating.
pub const NAME_CAP = 48;

// Seconds a slain monster takes to fade out.
pub const monster_death_fade = 0.55;

// Seconds a struck monster flashes white.
pub const monster_hitflash = 0.12;

// Kinds whose strike telegraph is carried ENTIRELY by the body animation (no red
// ground ring/beam), so their windup poses must stay unmistakable. Expressed as
// "everyone but the brute" so a new melee kind defaults to the body telegraph and
// must opt OUT explicitly, rather than silently getting a ground ring.
pub fn animTelegraph(kind: MonsterKind) bool {
    return kind != .brute;
}

// Pib pack panic (Diablo's Fallen): a packmate dying within this range scatters
// the pib for a few seconds. Aggro survives, so they regroup and return.
pub const flee_trigger_radius = 9.0;
pub const flee_time_min = 2.2;
pub const flee_time_rand = 1.6;

// ── Per-kind AI "personality" knobs ──────────────────────────────────────────
// Pib (Fallen) aggression: the knife pigs don't trudge, they dart. On a cadence a
// pib commits a fast dash that closes the gap, then recovers before the next.
pub const pib_lunge_cd_min = 2.4; // seconds between lunges…
pub const pib_lunge_cd_rand = 1.4; // …plus up to this much (desyncs a pack)
pub const pib_lunge_time = 0.32; // duration of the dash itself
pub const pib_lunge_speed = 2.6; // dash speed as a multiple of walk Speed
pub const pib_lunge_range = 9.0; // only lunge when the hero is within this
// A pib that eats a heavy single blow (this fraction of max HP) recoils and
// scatters — the SAME panic path as a packmate's death (see flee_* above).
pub const pib_recoil_frac = 0.28;

// Skeleton Archer footwork: when a player bolt bears down, juke sideways instead of
// eating it — but on a cooldown, so a line of archers isn't an un-hittable wall.
pub const skel_dodge_cd_min = 2.6;
pub const skel_dodge_cd_rand = 1.2;
pub const skel_dodge_time = 0.4; // duration of the strafe
pub const skel_dodge_speed = 1.5; // strafe speed as a multiple of walk Speed
pub const skel_dodge_sense = 6.5; // react to a player bolt closing within this range
pub const skel_dodge_align = 0.5; // min (bolt heading · dir-to-archer): below this the bolt is aimed elsewhere

// Monster is a hostile entity. AI is a simple wander/aggro/chase/attack loop.
pub const Monster = struct {
    id: i32 = 0,
    Kind: MonsterKind = .fallen,
    // Name stored INLINE, not sliced: a boss name aliased into the map would dangle
    // when the owning struct moves (see map.zig). Cap shared with Map.boss.
    name: mathx.StrBuf(NAME_CAP) = .{},
    Pos: rl.Vector3 = mathx.zero3,
    Facing: rl.Vector3 = mathx.zero3,
    HP: f32 = 0,
    MaxHP: f32 = 0,
    // Reserved for future mana-costing foe skills; populated but not yet consumed.
    Mana: f32 = 0,
    MaxMana: f32 = 0,
    Speed: f32 = 0,
    Radius: f32 = 0,
    Height: f32 = 0,
    Color: rl.Color = rl.Color.white,
    // Armor (PoE2 hit-size phys DR) + four elemental resists.
    def: stats.Defense = .{},
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
    swing: f32 = 0, // >0 while the strike arc plays; hit lands at its midpoint
    swingTime: f32 = 0, // 0 = no follow-through: hit resolves at windup end
    fleeTimer: f32 = 0, // >0 while scattering in panic (pibs; see flee_* above)
    lungeTimer: f32 = 0, // pib: >0 mid-lunge (a locked, boosted dash at the hero)
    lungeCD: f32 = 0, // pib: countdown to the next lunge
    dodgeTimer: f32 = 0, // skeleton: >0 mid-dodge (strafing off a bolt's line)
    dodgeCD: f32 = 0, // skeleton: countdown before it can juke a bolt again
    dodgeDir: rl.Vector3 = mathx.zero3, // skeleton: current strafe heading
    aggro: bool = false,
    hitFlash: f32 = 0,
    wanderTimer: f32 = 0,
    wanderDir: rl.Vector3 = mathx.zero3,
    bob: f32 = 0,
    deathTimer: f32 = 0, // >0 while the death fade plays, then removed
    dying: bool = false,
    boss: bool = false,

    // Stun. stunTimer > 0 = frozen (can't act); set by a light stun (single >25%-max
    // blow) or a heavy stun (meter topping out). stunFill (0→1) is the accumulating
    // heavy-stun meter (fills by landed/heavyStunMax, decays); at 1 it heavy-stuns
    // for heavyStunDur seconds.
    stunTimer: f32 = 0,
    stunFill: f32 = 0,
    heavyStunMax: f32 = 0, // damage to fill the meter (per-kind, scales with HP)
    heavyStunDur: f32 = 0, // heavy-stun seconds when the meter tops out

    // Chill (Ice Shard): while chillTimer > 0 the monster moves at chillFactor of its
    // Speed. Refreshed by each cold hit, keeping the STRONGER slow.
    chillTimer: f32 = 0,
    chillFactor: f32 = 1,

    pub fn alive(m: *const Monster) bool {
        return m.HP > 0 and !m.dying;
    }

    /// Movement speed multiplier from status (chill). 1 when unaffected.
    pub fn moveMult(m: *const Monster) f32 {
        return if (m.chillTimer > 0) m.chillFactor else 1;
    }

    /// Slow the monster to `factor` of its speed for `dur` seconds (keeping the stronger
    /// of any overlapping chills). Advanced/expired in `tickStatus`.
    pub fn applyChill(m: *Monster, dur: f32, factor: f32) void {
        // A fresh chill on an unchilled foe (factor reset to 1 by tickStatus) takes the
        // new factor; overlapping chills keep whichever slows more.
        m.chillFactor = if (m.chillTimer > 0) @min(m.chillFactor, factor) else factor;
        m.chillTimer = maxF(m.chillTimer, dur);
    }

    /// Advance status timers one frame (chill fades, resetting its factor when it ends).
    pub fn tickStatus(m: *Monster, dt: f32) void {
        if (m.chillTimer > 0) {
            m.chillTimer -= dt;
            if (m.chillTimer <= 0) m.chillFactor = 1;
        }
    }

    /// Frozen by a light or heavy stun: skip AI/attacks this frame.
    pub fn stunned(m: *const Monster) bool {
        return m.stunTimer > 0;
    }

    /// Apply a typed hit through defense and return the damage that landed. Also
    /// feeds the stun systems: a single big blow light-stuns (interrupting a
    /// windup), and every hit builds the heavy-stun meter.
    pub fn hurt(m: *Monster, dmg: stats.Damage) f32 {
        const landed = stats.mitigate(dmg, m.def);
        m.HP -= landed;
        m.hitFlash = monster_hitflash;
        m.aggro = true;
        // Light stun: a huge single blow staggers, cancelling an in-progress strike.
        if (m.HP > 0 and stats.isLightStun(landed, m.MaxHP)) {
            m.applyStun(stats.LIGHT_STUN_DUR);
        }
        // Heavy stun: accumulate toward the meter; topping out locks it down hard.
        if (m.HP > 0 and m.heavyStunMax > 0) {
            m.stunFill += stats.HEAVY_STUN_BUILD * landed / m.heavyStunMax;
            if (m.stunFill >= 1) {
                m.stunFill = 0;
                m.applyStun(m.heavyStunDur);
            }
        }
        return landed;
    }

    /// Freeze the monster for `dur` (max with any current stun) and cancel a
    /// committed strike so the stun genuinely interrupts.
    pub fn applyStun(m: *Monster, dur: f32) void {
        m.stunTimer = maxF(m.stunTimer, dur);
        m.windup = 0;
        m.swing = 0;
    }

    /// Advance stun timers/meter one frame. Returns true if still stunned after.
    pub fn tickStun(m: *Monster, dt: f32) bool {
        if (m.stunTimer > 0) m.stunTimer -= dt;
        if (m.stunFill > 0) {
            m.stunFill -= stats.HEAVY_STUN_DECAY_PER_SEC * dt;
            if (m.stunFill < 0) m.stunFill = 0;
        }
        return m.stunTimer > 0;
    }

    /// Telegraph progress 0→1 as a committed strike winds up (0 when idle). Shared
    /// by body pose, tint, and FX so drawn telegraph and strike timing can't drift.
    pub fn windupProgress(m: *const Monster) f32 {
        if (m.windup <= 0 or m.windupTime <= 0) return 0;
        return 1 - m.windup / m.windupTime;
    }

    /// Strike-arc progress 0→1 as the blow sweeps through (0 when idle). Shared by
    /// body pose, FX, and damage timing — the hit lands where the swing visibly is.
    pub fn swingProgress(m: *const Monster) f32 {
        if (m.swing <= 0 or m.swingTime <= 0) return 0;
        return 1 - m.swing / m.swingTime;
    }

    /// Send the monster into a panic scatter for a randomized duration, keeping the
    /// LONGER of any current scatter (a follow-up blow or kill-chain must never shorten
    /// a running panic). One source for the flee-duration roll — pib recoil (a heavy
    /// blow) and a nearby death both route through here.
    pub fn startFlee(m: *Monster, rng: *Rng) void {
        m.fleeTimer = maxF(m.fleeTimer, flee_time_min + rng.float() * flee_time_rand);
    }

    pub fn fleeing(m: *const Monster) bool {
        return m.fleeTimer > 0;
    }
};

// makeMonster builds a monster of the given kind, scaled by difficulty tier.
pub fn makeMonster(kind: MonsterKind, tier: i32, rng: *Rng, pos: rl.Vector3) Monster {
    // rng seeds each kind's behavior cooldown to a random initial value so a freshly
    // spawned pack lunges/dodges out of sync rather than in a single wave; base stats
    // stay deterministic.
    const t: f32 = @floatFromInt(tier);
    var m = Monster{ .Kind = kind, .Pos = pos, .Facing = v3(0, 0, 1) };
    // Heavy-stun meter as a multiple of MaxHP (per kind): tankier = harder to
    // stagger. Applied after MaxHP is known.
    var stunFactor: f32 = undefined; // every kind arm below sets it (switch is exhaustive)
    switch (kind) {
        .fallen => {
            m.name.set("Pib"); // the knife pigs (gf-certified)
            m.MaxHP = 30 + t * 11;
            m.Radius = 0.45;
            m.Height = 1.4;
            m.Color = rgba(170, 60, 50, 255);
            m.MinDmg = 10 + t * 2;
            m.MaxDmg = 16 + t * 3;
            m.XP = 9 + tier * 4;
            m.GoldDrop = 4 + tier * 3;
            m.atkRange = 1.7;
            m.sightRange = 14;
            // Fast and jittery: the knife pigs move quicker and stab more often than
            // the rest of the bestiary, and they close the gap in bursts (lunge).
            m.Speed = 4.4 + t * 0.25;
            m.atkRate = 1.25;
            // Knife arc IS the telegraph (no ground ring): windup cocks the blade,
            // swing whips it through — the cock is the readable beat. Snappy but legible.
            m.windupTime = 0.42;
            m.swingTime = 0.22;
            m.def.armor = 4 + t * 1;
            m.heavyStunDur = 1.1;
            stunFactor = 1.2; // squishy: easy to stagger
            m.lungeCD = rng.float() * pib_lunge_cd_min; // stagger first lunge across the pack
        },
        .zombie => {
            m.name.set("Zombie");
            // A lumbering wall: too slow to catch the alert, too tanky to ignore,
            // and its overhead slam ruins whoever stands in it.
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
            m.atkRate = 2.9; // still ponderous, but the slam comes around a bit sooner
            // Long overhead raise (the whole telegraph — must let even a walking
            // player leave), then a near-instant guillotine drop. A touch snappier now.
            m.windupTime = 1.0;
            m.swingTime = 0.18;
            m.def.armor = 45 + t * 6; // a wall: shrugs off small hits
            m.def.setRes(.cold, 0.3); // rotting meat doesn't feel the chill
            m.heavyStunDur = 2.2; // rare, but a toppled zombie stays down
            stunFactor = 1.7;
        },
        .skeleton => {
            m.name.set("Skeleton Archer");
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
            // The draw IS the telegraph (no aiming beam) — long enough to read
            // and sidestep.
            m.windupTime = 0.75;
            m.def.armor = 6 + t * 1.5;
            m.heavyStunDur = 1.4;
            stunFactor = 1.2;
            m.dodgeCD = rng.float() * skel_dodge_cd_min; // stagger first juke across the line
        },
        .brute => {
            m.name.set("Brute");
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
            m.def.armor = 70 + t * 9; // heavily plated
            m.def.setRes(.fire, 0.2);
            m.heavyStunDur = 1.8;
            stunFactor = 1.6;
        },
    }
    m.HP = m.MaxHP;
    m.MaxMana = 0; // no kind spends mana yet (reserved for future skills)
    m.Mana = m.MaxMana;
    // Meter scales with the monster's own health: higher tiers need proportionally
    // more punishment to stagger.
    m.heavyStunMax = m.MaxHP * stunFactor;
    return m;
}

// makeBoss promotes a brute into the area's champion. Name supplied by the caller
// (map's `boss:` field), so there's no parallel tier->name table to sync.
pub fn makeBoss(tier: i32, bossName: []const u8, rng: *Rng, pos: rl.Vector3) Monster {
    var m = makeMonster(.brute, tier, rng, pos);
    m.boss = true;
    m.name.set(bossName); // copied, not aliased: the caller's map may move
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
    // Champion: resistant, extra armor, hard to stagger. Rescale the stun meter off
    // the boosted HP (makeMonster sized it to base brute HP, before the ×2.4+120).
    m.def.armor += 40;
    m.def.setAllElemental(0.25);
    m.heavyStunDur = 2.4;
    m.heavyStunMax = m.MaxHP * 1.8;
    return m;
}
