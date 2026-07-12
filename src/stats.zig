const std = @import("std");
const mathx = @import("mathx.zig");

const clampF = mathx.clampF;
const maxF = mathx.maxF;

// stats.zig — the RPG layer: attributes, typed damage, armor/resist mitigation, and
// attribute→derived-stat math. Pure data + math (no raylib/game state) so player and
// monster share formulas. All balance knobs live in TUNING.

// `physical` is index 0 so armor (phys-only) keys off it cleanly; poison folds into
// chaos (no separate type).
pub const DamageType = enum(u3) {
    physical,
    fire,
    cold,
    lightning,
    chaos,

    // Self-maintaining (mirrors player.Skill.count): a new variant grows the damage
    // packet / resist arrays automatically instead of silently staying length-5.
    pub const count = @typeInfo(DamageType).@"enum".fields.len;
    // The four non-physical types, in canonical order. The single source for
    // "iterate the elements" (resist rows, setAllElemental) — no hand-synced list.
    pub const elementals = [_]DamageType{ .fire, .cold, .lightning, .chaos };

    pub fn idx(t: DamageType) usize {
        return @intFromEnum(t);
    }
    pub fn isElemental(t: DamageType) bool {
        return t != .physical;
    }
    pub fn label(t: DamageType) [:0]const u8 {
        return switch (t) {
            .physical => "Physical",
            .fire => "Fire",
            .cold => "Cold",
            .lightning => "Lightning",
            .chaos => "Chaos",
        };
    }
};

// A typed damage packet: how much of each type one hit carries (fire arrow =
// phys+fire, ice bolt = cold). Mitigation is applied per component.
pub const Damage = struct {
    amt: [DamageType.count]f32 = [_]f32{0} ** DamageType.count,

    pub fn one(t: DamageType, v: f32) Damage {
        var d = Damage{};
        d.amt[t.idx()] = v;
        return d;
    }
    pub fn phys(v: f32) Damage {
        return one(.physical, v);
    }
    pub fn get(d: Damage, t: DamageType) f32 {
        return d.amt[t.idx()];
    }
    pub fn set(d: *Damage, t: DamageType, v: f32) void {
        d.amt[t.idx()] = v;
    }
    pub fn addType(d: *Damage, t: DamageType, v: f32) void {
        d.amt[t.idx()] += v;
    }
    pub fn total(d: Damage) f32 {
        var s: f32 = 0;
        for (d.amt) |v| s += v;
        return s;
    }
    /// Scale every component by `k` (crit, buffs, etc.).
    pub fn scaled(d: Damage, k: f32) Damage {
        var out = d;
        for (&out.amt) |*v| v.* *= k;
        return out;
    }
};

// Defense: armor (physical only) + four elemental resists. res[physical] is unused;
// armor is ignored for elemental hits.
pub const Defense = struct {
    armor: f32 = 0,
    // res[physical] unused; res[fire..chaos] are fractions in [RES_MIN, RES_CAP].
    res: [DamageType.count]f32 = [_]f32{0} ** DamageType.count,

    pub fn resFor(def: Defense, t: DamageType) f32 {
        return def.res[t.idx()];
    }
    pub fn setRes(def: *Defense, t: DamageType, v: f32) void {
        def.res[t.idx()] = v;
    }
    /// Set all four elemental resists at once (common for un-themed monsters).
    pub fn setAllElemental(def: *Defense, v: f32) void {
        for (DamageType.elementals) |t| def.res[t.idx()] = v;
    }
};

// ── TUNING — the only place balance numbers live ──
// Multipliers are increases FROM the anchor, so a level-1 hero reproduces the old
// hardcoded feel and each allocated point is a clean increment.

pub const ATTR_ANCHOR: f32 = 10; // starting vit/str/dex/int/focus
pub const LUCK_ANCHOR: f32 = 5; // starting luck (rarer, stronger per point)

// Vitality → life. (old: MaxHP 100, hpRegen 0.4 at vit 10)
pub const BASE_HP: f32 = 40;
pub const HP_PER_VIT: f32 = 6;
pub const BASE_HP_REGEN: f32 = 0.1;
pub const HP_REGEN_PER_VIT: f32 = 0.03;

// Focus → mana. (old: MaxMana 50, manaRegen 3.0 at focus 10)
pub const BASE_MANA: f32 = 10;
pub const MANA_PER_FOCUS: f32 = 4;
pub const BASE_MANA_REGEN: f32 = 1.0;
pub const MANA_REGEN_PER_FOCUS: f32 = 0.2;

// Str → melee %inc; Dex → ranged %inc + cast speed; Int → spell %inc + CDR.
// All measured from anchor.
pub const MELEE_INC_PER_STR: f32 = 0.02; // +2% melee dmg per str over anchor
pub const RANGED_INC_PER_DEX: f32 = 0.02; // +2% ranged dmg per dex over anchor
pub const SPELL_INC_PER_INT: f32 = 0.05; // +5% spell dmg per int over anchor (+1 base/pt)
pub const CAST_SPEED_INC_PER_DEX: f32 = 0.015; // +1.5% cast/attack speed per dex
pub const CDR_PER_INT: f32 = 0.01; // +1% cooldown reduction per int over anchor
pub const CDR_CAP: f32 = 0.60; // cooldowns never shrink past 60%
pub const CAST_SPEED_CAP: f32 = 2.5; // and never speed past 2.5x

// Luck → crit chance, drop luck, status-effect chance. (old crit: 0.15)
pub const BASE_CRIT: f32 = 0.125;
pub const CRIT_PER_LUCK: f32 = 0.005; // → 0.15 at luck 5
pub const CRIT_CAP: f32 = 0.75;
pub const CRIT_MULT: f32 = 2.0; // crit damage multiplier (was game.zig CRIT_MULT)
pub const DROP_LUCK_PER_LUCK: f32 = 0.03; // +3% drop luck per luck over anchor
pub const STATUS_PER_LUCK: f32 = 0.01; // +1% status-application chance per luck

// Armor: PoE2 hit-size model — reduction = armor/(armor + K·rawPhysHit), so fixed
// armor shrugs off small hits but is punched through by big ones.
pub const ARMOR_K: f32 = 5.0;
pub const PHYS_DR_CAP: f32 = 0.90; // even a mountain of armor leaves 10% through

pub const RES_CAP: f32 = 0.75; // elemental resist cap, PoE2-style
pub const RES_MIN: f32 = -1.0; // -100% (double damage) is the floor

// Light stun: a post-mitigation hit above this fraction of max HP briefly interrupts
// (players can ONLY be light-stunned). Heavy stun (monsters) is a decaying meter, see
// monster.zig.
pub const LIGHT_STUN_HP_FRAC: f32 = 0.25;
pub const LIGHT_STUN_DUR: f32 = 0.35; // seconds of interrupt
pub const HEAVY_STUN_DECAY_PER_SEC: f32 = 0.11; // fraction of the meter drained/sec (slow: the meter lingers)

// ── Attributes ───────────────────────────────────────────────────────────────
pub const Attribs = struct {
    vitality: i32 = @intFromFloat(ATTR_ANCHOR),
    strength: i32 = @intFromFloat(ATTR_ANCHOR),
    dexterity: i32 = @intFromFloat(ATTR_ANCHOR),
    intelligence: i32 = @intFromFloat(ATTR_ANCHOR),
    focus: i32 = @intFromFloat(ATTR_ANCHOR),
    luck: i32 = @intFromFloat(LUCK_ANCHOR),

    /// Attributes in stat-sheet display order, with label + effect note. Kept here so
    /// the sheet UI and allocation code iterate ONE list, not six hardcoded rows.
    pub const Kind = enum { vitality, strength, dexterity, intelligence, focus, luck };
    pub const order = [_]Kind{ .vitality, .strength, .dexterity, .intelligence, .focus, .luck };

    pub fn label(k: Kind) [:0]const u8 {
        return switch (k) {
            .vitality => "Vitality",
            .strength => "Strength",
            .dexterity => "Dexterity",
            .intelligence => "Intelligence",
            .focus => "Focus",
            .luck => "Luck",
        };
    }
    pub fn note(k: Kind) [:0]const u8 {
        return switch (k) {
            .vitality => "Life & life regen",
            .strength => "Melee damage",
            .dexterity => "Ranged damage & attack speed",
            .intelligence => "Spell damage & cooldown reduction",
            .focus => "Mana & mana regen",
            .luck => "Crit, drop luck & status chance",
        };
    }
    pub fn get(a: Attribs, k: Kind) i32 {
        return switch (k) {
            .vitality => a.vitality,
            .strength => a.strength,
            .dexterity => a.dexterity,
            .intelligence => a.intelligence,
            .focus => a.focus,
            .luck => a.luck,
        };
    }
    pub fn addPoint(a: *Attribs, k: Kind) void {
        switch (k) {
            .vitality => a.vitality += 1,
            .strength => a.strength += 1,
            .dexterity => a.dexterity += 1,
            .intelligence => a.intelligence += 1,
            .focus => a.focus += 1,
            .luck => a.luck += 1,
        }
    }
};

// ── Derived stats ──────────────────────────────────────────────────────────
// Everything combat reads, computed from Attribs by `derive`. Recomputed whenever
// attributes change; never hand-edited.
pub const Derived = struct {
    maxHP: f32 = 0,
    hpRegen: f32 = 0,
    maxMana: f32 = 0,
    manaRegen: f32 = 0,

    meleeMult: f32 = 1, // multiply base melee damage
    rangedMult: f32 = 1, // RESERVED: no hero ranged attack yet (dexterity's ranged half)
    spellMult: f32 = 1, // multiply spell (firebolt) damage
    castSpeedMult: f32 = 1, // >1 = faster: divide attack/cast cooldowns by this
    cdrFrac: f32 = 0, // 0..CDR_CAP: multiply skill cooldowns by (1 - cdrFrac)

    critChance: f32 = 0,
    dropLuck: f32 = 0, // RESERVED: additive drop-roll bonus, not yet consumed
    statusChance: f32 = 0, // RESERVED: status-application chance, not yet consumed
};

fn incFrom(value: i32, anchor: f32, perPoint: f32) f32 {
    return (@as(f32, @floatFromInt(value)) - anchor) * perPoint;
}

pub fn derive(a: Attribs) Derived {
    const vit: f32 = @floatFromInt(a.vitality);
    const foc: f32 = @floatFromInt(a.focus);
    const luck: f32 = @floatFromInt(a.luck);
    return .{
        .maxHP = BASE_HP + HP_PER_VIT * vit,
        .hpRegen = BASE_HP_REGEN + HP_REGEN_PER_VIT * vit,
        .maxMana = BASE_MANA + MANA_PER_FOCUS * foc,
        .manaRegen = BASE_MANA_REGEN + MANA_REGEN_PER_FOCUS * foc,

        .meleeMult = 1 + incFrom(a.strength, ATTR_ANCHOR, MELEE_INC_PER_STR),
        .rangedMult = 1 + incFrom(a.dexterity, ATTR_ANCHOR, RANGED_INC_PER_DEX),
        .spellMult = 1 + incFrom(a.intelligence, ATTR_ANCHOR, SPELL_INC_PER_INT),
        .castSpeedMult = clampF(1 + incFrom(a.dexterity, ATTR_ANCHOR, CAST_SPEED_INC_PER_DEX), 1, CAST_SPEED_CAP),
        .cdrFrac = clampF(incFrom(a.intelligence, ATTR_ANCHOR, CDR_PER_INT), 0, CDR_CAP),

        .critChance = clampF(BASE_CRIT + CRIT_PER_LUCK * luck, 0, CRIT_CAP),
        .dropLuck = maxF(0, incFrom(a.luck, LUCK_ANCHOR, DROP_LUCK_PER_LUCK)),
        .statusChance = maxF(0, incFrom(a.luck, LUCK_ANCHOR, STATUS_PER_LUCK)),
    };
}

// ── Mitigation ───────────────────────────────────────────────────────────────

/// Physical DR fraction for a raw hit of `rawHit` against `armor` (PoE2 hit-size
/// curve). Returns 0 when there's no hit.
pub fn physReduction(armor: f32, rawHit: f32) f32 {
    if (armor <= 0 or rawHit <= 0) return 0;
    return clampF(armor / (armor + ARMOR_K * rawHit), 0, PHYS_DR_CAP);
}

/// Apply a defense to a typed packet, returning total damage landed. Physical uses
/// the armor curve (sized to THIS hit's phys component); each elemental component is
/// cut by its capped resist. THE mitigation entry point for hero and monsters.
pub fn mitigate(dmg: Damage, def: Defense) f32 {
    const physIdx = @intFromEnum(DamageType.physical);
    var total: f32 = 0;
    for (dmg.amt, 0..) |raw, i| {
        if (raw <= 0) continue;
        if (i == physIdx) {
            total += raw * (1 - physReduction(def.armor, raw));
        } else {
            const r = clampF(def.res[i], RES_MIN, RES_CAP);
            total += raw * (1 - r);
        }
    }
    return maxF(0, total);
}

/// Would a post-mitigation hit of `landed` light-stun a victim with `maxHP` max HP?
/// Shared by player and monster so the 25%-of-max rule lives once.
pub fn isLightStun(landed: f32, maxHP: f32) bool {
    return maxHP > 0 and landed > LIGHT_STUN_HP_FRAC * maxHP;
}
