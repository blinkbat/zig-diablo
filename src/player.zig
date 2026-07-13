const rl = @import("raylib");
const mathx = @import("mathx.zig");
const stats = @import("stats.zig");

const v3 = mathx.v3;
const lenXZ = mathx.lenXZ;
const minF = mathx.minF;
const maxF = mathx.maxF;
const clampF = mathx.clampF;

// Dodge-roll tuning: a short fast burst with a generous i-frame window — the core
// way to survive telegraphed attacks.
pub const rollDur = 0.38;
pub const rollSpeed = 15.0;
pub const rollCDMax = 1.05;
pub const rollIframe = 0.34;

// Melee swing animation length (seconds).
pub const swingDur = 0.22;

// Seconds the hero flashes white when struck.
pub const hitflash = 0.25;

pub const maxPots = 9;

// Belt-potion potency: a percentage of the max pool plus a flat floor, so early
// potions still meaningfully heal before pools grow.
pub const POTION_HEAL_FRAC = 0.55;
pub const POTION_HEAL_FLAT = 30;
pub const POTION_MANA_FRAC = 0.6;
pub const POTION_MANA_FLAT = 20;

// Hero collision radius — the single source of truth (no per-player field; never
// varies at runtime). Used for movement collision and melee reach, and read by the
// monster telegraph so the drawn ring matches the real hitbox.
pub const radius: f32 = 0.55;

// ── Base kit (pre-attribute) ─────────────────────────────────────────────────
// Level-1, anchor-attribute numbers. recompute() multiplies these by
// attribute/skill scaling; at the starting spread the multipliers are 1.0, so these
// reproduce the old hardcoded feel — balance is unchanged until you allocate.
pub const BASE_MELEE_MIN: f32 = 9;
pub const BASE_MELEE_MAX: f32 = 15;
pub const BASE_SPELL_DMG: f32 = 20;
pub const BASE_ATK_RATE: f32 = 0.85;
pub const BASE_CAST_RATE: f32 = 0.7;
pub const BASE_SPELL_COST: f32 = 7;
// No gear yet: modest innate armor (item armor will add here later). Resists start 0.
pub const BASE_ARMOR: f32 = 20;

// Points granted per level (Diablo-2 style: allocated by hand).
pub const ATTR_POINTS_PER_LEVEL: i32 = 5;
pub const SKILL_POINTS_PER_LEVEL: i32 = 1;

// Per-rank skill bumps (no full tree yet — points rank up the three skills).
pub const MELEE_RANK_INC: f32 = 0.08; // +8% melee damage per rank over 1
pub const FIREBOLT_RANK_INC: f32 = 0.12; // +12% firebolt damage per rank over 1
pub const DODGE_RANK_IFRAME: f32 = 0.04; // +0.04s i-frames per rank over 1
pub const DODGE_RANK_CD: f32 = 0.06; // -0.06s roll cooldown per rank over 1
pub const DODGE_CD_FLOOR: f32 = 0.55; // roll cooldown never shrinks below this

// The three skills; skill points rank these up. Label lives with the enum (like
// stats.Attribs) so the sheet iterates one source, not a parallel list.
pub const Skill = enum {
    melee,
    firebolt,
    dodge,

    pub const count = @typeInfo(Skill).@"enum".fields.len;

    pub fn label(s: Skill) [:0]const u8 {
        return switch (s) {
            .melee => "Melee",
            .firebolt => "Firebolt",
            .dodge => "Dodge",
        };
    }
};

// Player is the hero — an Amazon-ish ranged/melee hybrid.
pub const Player = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Facing: rl.Vector3 = mathx.zero3,
    Speed: f32 = 0,

    Level: i32 = 0,
    XP: i32 = 0,
    XPNext: i32 = 0,

    // ── RPG layer ──
    attribs: stats.Attribs = .{},
    derived: stats.Derived = .{},
    def: stats.Defense = .{ .armor = BASE_ARMOR },
    attrPoints: i32 = 0,
    skillPoints: i32 = 0,
    meleeRank: i32 = 1,
    fireboltRank: i32 = 1,
    dodgeRank: i32 = 1,

    HP: f32 = 0,
    MaxHP: f32 = 0,
    Mana: f32 = 0,
    MaxMana: f32 = 0,
    hpRegen: f32 = 0,
    manaRegen: f32 = 0,

    MinDmg: f32 = 0,
    MaxDmg: f32 = 0,
    Gold: i32 = 0,

    HealthPots: i32 = 0,
    ManaPots: i32 = 0,

    // Movement intent (click-to-move).
    moveTarget: rl.Vector3 = mathx.zero3,
    hasMoveTarget: bool = false,
    // Targeting. `targetMonster` is the SELECTED foe — always-on nearest by default, or a
    // sticky manual pick (mouse hover / right-stick). It drives facing, firebolt aim, and
    // the on-model + HUD indicator, but never moves the hero. `chaseMonster` is the foe you
    // EXPLICITLY engaged (click / pad X) to chase into melee — the only one the hero walks
    // toward and auto-attacks. Both are monster ids, or -1.
    targetMonster: i32 = -1,
    chaseMonster: i32 = -1,

    // Combat timers.
    atkCD: f32 = 0,
    atkRate: f32 = 0,
    atkRange: f32 = 0,
    castCD: f32 = 0,
    castRate: f32 = 0,

    // Dodge roll.
    rollTimer: f32 = 0,
    rollCD: f32 = 0,
    rollDir: rl.Vector3 = mathx.zero3,
    iframe: f32 = 0,

    // Light stun: brief interrupt when a single blow lands for >25% of max HP. The
    // hero can ONLY be light-stunned (never heavy-stunned like an enemy).
    stunTimer: f32 = 0,

    // Spell (Firebolt).
    spellCost: f32 = 0,
    spellDmg: f32 = 0,

    // Presentation.
    swing: f32 = 0,
    hitFlash: f32 = 0,
    walkBob: f32 = 0,

    pub fn alive(p: *const Player) bool {
        return p.HP > 0;
    }
    pub fn invulnerable(p: *const Player) bool {
        return p.iframe > 0;
    }
    pub fn rolling(p: *const Player) bool {
        return p.rollTimer > 0;
    }
    /// Light-stunned: can't attack, cast, or steer until it wears off.
    pub fn stunned(p: *const Player) bool {
        return p.stunTimer > 0;
    }

    /// Recompute every derived combat number from current attributes + skill ranks.
    /// Called on spawn, level-up, and allocation. Preserves the HP/Mana FILL RATIO so
    /// raising max life doesn't retroactively heal.
    pub fn recompute(p: *Player) void {
        const hpFrac = if (p.MaxHP > 0) p.HP / p.MaxHP else 1;
        const manaFrac = if (p.MaxMana > 0) p.Mana / p.MaxMana else 1;

        p.derived = stats.derive(p.attribs);
        p.MaxHP = p.derived.maxHP;
        p.MaxMana = p.derived.maxMana;
        p.hpRegen = p.derived.hpRegen;
        p.manaRegen = p.derived.manaRegen;

        const meleeRankMult = 1 + MELEE_RANK_INC * @as(f32, @floatFromInt(p.meleeRank - 1));
        p.MinDmg = BASE_MELEE_MIN * p.derived.meleeMult * meleeRankMult;
        p.MaxDmg = BASE_MELEE_MAX * p.derived.meleeMult * meleeRankMult;

        const fbRankMult = 1 + FIREBOLT_RANK_INC * @as(f32, @floatFromInt(p.fireboltRank - 1));
        p.spellDmg = BASE_SPELL_DMG * p.derived.spellMult * fbRankMult;

        // Cast-speed shortens cooldowns; int's CDR shortens the spell cooldown more.
        p.atkRate = BASE_ATK_RATE / p.derived.castSpeedMult;
        p.castRate = BASE_CAST_RATE * (1 - p.derived.cdrFrac) / p.derived.castSpeedMult;

        p.HP = hpFrac * p.MaxHP;
        p.Mana = manaFrac * p.MaxMana;
    }

    /// Roll i-frame duration for the current dodge rank.
    pub fn rollIframeDur(p: *const Player) f32 {
        return rollIframe + DODGE_RANK_IFRAME * @as(f32, @floatFromInt(p.dodgeRank - 1));
    }
    /// Roll cooldown for the current dodge rank (floored so it can't trivialize).
    pub fn rollCooldown(p: *const Player) f32 {
        return maxF(DODGE_CD_FLOOR, rollCDMax - DODGE_RANK_CD * @as(f32, @floatFromInt(p.dodgeRank - 1)));
    }

    pub fn addXP(p: *Player, amount: i32) bool {
        var leveled = false;
        p.XP += amount;
        while (p.XP >= p.XPNext) {
            p.XP -= p.XPNext;
            p.Level += 1;
            p.XPNext = xpForLevel(p.Level);
            p.levelUp();
            leveled = true;
        }
        return leveled;
    }

    /// A level grants points to allocate (no automatic stat bumps) and, Diablo-style,
    /// fully restores you.
    pub fn levelUp(p: *Player) void {
        p.attrPoints += ATTR_POINTS_PER_LEVEL;
        p.skillPoints += SKILL_POINTS_PER_LEVEL;
        p.recompute();
        p.HP = p.MaxHP;
        p.Mana = p.MaxMana;
    }

    /// Spend one attribute point on `k`. False if none are available.
    pub fn allocAttr(p: *Player, k: stats.Attribs.Kind) bool {
        if (p.attrPoints <= 0) return false;
        p.attrPoints -= 1;
        p.attribs.addPoint(k);
        p.recompute();
        return true;
    }

    /// Current rank of a skill (skills start at rank 1).
    pub fn skillRank(p: *const Player, s: Skill) i32 {
        return switch (s) {
            .melee => p.meleeRank,
            .firebolt => p.fireboltRank,
            .dodge => p.dodgeRank,
        };
    }

    /// Spend one skill point ranking up `s`. False if none are available.
    pub fn allocSkill(p: *Player, s: Skill) bool {
        if (p.skillPoints <= 0) return false;
        p.skillPoints -= 1;
        switch (s) {
            .melee => p.meleeRank += 1,
            .firebolt => p.fireboltRank += 1,
            .dodge => p.dodgeRank += 1,
        }
        p.recompute();
        return true;
    }

    /// Begin a dodge in dir (falling back to facing). False if on cooldown/underway.
    pub fn startRoll(p: *Player, dir_in: rl.Vector3) bool {
        if (p.rollCD > 0 or p.rollTimer > 0 or p.stunned() or !p.alive()) return false;
        var dir = dir_in;
        if (lenXZ(dir) < 1e-3) dir = p.Facing;
        if (lenXZ(dir) < 1e-3) dir = v3(0, 0, -1);
        p.rollDir = dir;
        p.Facing = dir;
        p.rollTimer = rollDur;
        p.rollCD = p.rollCooldown();
        p.iframe = p.rollIframeDur();
        // A roll interrupts whatever you were doing.
        p.hasMoveTarget = false;
        p.chaseMonster = -1; // drop the chase; the selection re-resolves next frame
        return true;
    }

    /// Take a typed hit. Armor + resists applied via the shared mitigation path;
    /// returns the damage that landed so callers can gate feedback FX. A blow above
    /// the light-stun threshold briefly interrupts the hero and cancels a swing/cast.
    pub fn takeDamage(p: *Player, dmg: stats.Damage) f32 {
        const landed = stats.mitigate(dmg, p.def);
        p.HP -= landed;
        if (p.HP < 0) p.HP = 0;
        p.hitFlash = hitflash;
        if (p.alive() and stats.isLightStun(landed, p.MaxHP)) {
            p.stunTimer = maxF(p.stunTimer, stats.LIGHT_STUN_DUR);
            p.swing = 0; // interrupt an in-progress melee swing
        }
        return landed;
    }

    /// Clear transient combat/roll/stun state. Called on an area transition so a
    /// roll or stun in progress at the portal doesn't carry into the next area
    /// (sliding off spawn mid-roll, or spawning rooted and stunned).
    pub fn resetCombatState(p: *Player) void {
        p.rollTimer = 0;
        p.rollCD = 0;
        p.iframe = 0;
        p.stunTimer = 0;
        p.swing = 0;
        p.atkCD = 0;
        p.castCD = 0;
        p.hasMoveTarget = false;
        p.targetMonster = -1;
        p.chaseMonster = -1;
    }

    pub fn regen(p: *Player, dt: f32) void {
        if (p.HP <= 0) return; // the dead don't regen HP or mana
        if (p.HP < p.MaxHP) p.HP = minF(p.MaxHP, p.HP + p.hpRegen * dt);
        if (p.Mana < p.MaxMana) p.Mana = minF(p.MaxMana, p.Mana + p.manaRegen * dt);
    }

    pub fn drinkHealth(p: *Player) bool {
        if (p.HealthPots <= 0 or p.HP >= p.MaxHP) return false;
        p.HealthPots -= 1;
        p.HP = minF(p.MaxHP, p.HP + p.MaxHP * POTION_HEAL_FRAC + POTION_HEAL_FLAT);
        return true;
    }

    pub fn drinkMana(p: *Player) bool {
        if (p.ManaPots <= 0 or p.Mana >= p.MaxMana) return false;
        p.ManaPots -= 1;
        p.Mana = minF(p.MaxMana, p.Mana + p.MaxMana * POTION_MANA_FRAC + POTION_MANA_FLAT);
        return true;
    }
};

pub fn newPlayer(pos: rl.Vector3) Player {
    var p = Player{
        .Pos = pos,
        .Facing = v3(0, 0, -1),
        .Speed = 4.6, // deliberate, weighty walk
        .Level = 1,
        .XP = 0,
        .Gold = 0,
        .HealthPots = 4,
        .ManaPots = 2,
        .targetMonster = -1,
        .atkRange = 2.4,
        .spellCost = BASE_SPELL_COST,
        .def = .{ .armor = BASE_ARMOR },
    };
    // Derive stats from the starting attributes, then top off.
    p.recompute();
    p.HP = p.MaxHP;
    p.Mana = p.MaxMana;
    p.XPNext = xpForLevel(p.Level);
    return p;
}

// xpForLevel is the XP required to advance FROM the given level. Levels are
// 1-based; a below-1 level (e.g. a default-constructed player) would make the
// curve return a negative threshold and spin the level-up loop, so floor it.
pub fn xpForLevel(level: i32) i32 {
    const l = if (level < 1) 1 else level;
    return 40 + (l - 1) * 55 + (l - 1) * (l - 1) * 12;
}
