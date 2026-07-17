const std = @import("std");
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

// Per-rank skill bumps (no full tree yet — points rank up the three rankable skills).
pub const MELEE_RANK_INC: f32 = 0.08; // +8% melee damage per rank over 1
pub const FIREBOLT_RANK_INC: f32 = 0.12; // +12% firebolt damage per rank over 1
pub const DODGE_RANK_IFRAME: f32 = 0.04; // +0.04s i-frames per rank over 1
pub const DODGE_RANK_CD: f32 = 0.06; // -0.06s roll cooldown per rank over 1
pub const DODGE_CD_FLOOR: f32 = 0.55; // roll cooldown never shrinks below this

// ── Extra-skill kit ──────────────────────────────────────────────────────────
// The five reassignable skills beyond the core three. Combat numbers are level-1
// anchors; damage scales at cast time by the matching derived mult (spell / ranged /
// melee), so allocating Int/Dex/Str powers them without a rank system of their own.
// These are NOT rankable (like the potions) — spatial reach/radius lives in game.zig.
pub const ICE_DMG: f32 = 16; // cold, single target
pub const ICE_COST: f32 = 6;
pub const ICE_CD: f32 = 0.55;
pub const CHILL_DUR: f32 = 2.0; // seconds a struck foe is slowed
pub const CHILL_FACTOR: f32 = 0.55; // chilled foes move at 55% speed

pub const NOVA_DMG: f32 = 26; // lightning, AoE burst around the hero
pub const NOVA_COST: f32 = 15;
pub const NOVA_CD: f32 = 2.2;

pub const FLASK_DPS: f32 = 16; // chaos poison cloud, damage-over-time AoE
pub const FLASK_COST: f32 = 12;
pub const FLASK_CD: f32 = 3.4;

pub const KNIFE_MIN: f32 = 7; // physical ranged, cheap and quick (no mana)
pub const KNIFE_MAX: f32 = 12;
pub const KNIFE_CD: f32 = 0.34;

pub const CLEAVE_CD: f32 = 0.85; // physical melee, hits every foe in a frontal arc

// The three skills; skill points rank these up. Label lives with the enum (like
// stats.Attribs) so the sheet iterates one source, not a parallel list.
pub const Skill = enum {
    // Physical
    melee,
    cleave, // frontal-arc AoE swing
    throwing_knife, // physical ranged
    // Elemental spells
    firebolt, // fire, single target
    ice_shard, // cold, single target — chills
    lightning_nova, // lightning, AoE burst
    toxic_flask, // chaos, lingering DoT cloud
    // Movement
    dodge,
    // Consumables — potion use is a reassignable action too, so it lives on the bar
    // alongside the combat skills. Not rankable; draws from the belt counts.
    health_potion,
    mana_potion,

    pub const count = @typeInfo(Skill).@"enum".fields.len;
    // Canonical variant list — the single source for "iterate every skill" (skill-bar
    // palette, sheet). Hand-listed, so the assert pins it: a new Skill without a matching
    // entry here is a compile error rather than a silently-missing palette chip.
    pub const all = [_]Skill{ .melee, .cleave, .throwing_knife, .firebolt, .ice_shard, .lightning_nova, .toxic_flask, .dodge, .health_potion, .mana_potion };
    comptime {
        std.debug.assert(all.len == count);
    }

    // Consumables fire on a button TAP (one per press) and draw from a belt count;
    // combat skills fire while held and never run out. One source so input + HUD agree.
    pub fn consumable(s: Skill) bool {
        return s == .health_potion or s == .mana_potion;
    }

    // Rankable by skill points (the original three). The rest — potions and the five
    // extra skills — scale off attributes instead, so they get no allocation row.
    pub fn rankable(s: Skill) bool {
        return s == .melee or s == .firebolt or s == .dodge;
    }

    // Aimed skills fire toward the selected foe / cursor point (projectiles). Melee-family
    // and self-centered bursts key off the chase target or the hero, not an aim point.
    pub fn wantsAim(s: Skill) bool {
        return switch (s) {
            .firebolt, .ice_shard, .throwing_knife, .toxic_flask => true,
            else => false,
        };
    }

    // Offensive skills make the gamepad acquire a target + project an aim point before
    // firing (mirrors the old X-attack acquire). Movement/consumables don't.
    pub fn offensive(s: Skill) bool {
        return switch (s) {
            .melee, .cleave, .throwing_knife, .firebolt, .ice_shard, .toxic_flask => true,
            .lightning_nova, .dodge, .health_potion, .mana_potion => false,
        };
    }

    // Mana this skill draws per use (0 = free). One source so the HUD readiness veil and
    // the cast gate can't disagree.
    pub fn manaCost(s: Skill) f32 {
        return switch (s) {
            .firebolt => BASE_SPELL_COST,
            .ice_shard => ICE_COST,
            .lightning_nova => NOVA_COST,
            .toxic_flask => FLASK_COST,
            else => 0,
        };
    }

    pub fn label(s: Skill) [:0]const u8 {
        return switch (s) {
            .melee => "Melee",
            .cleave => "Cleave",
            .throwing_knife => "Throwing Knife",
            .firebolt => "Firebolt",
            .ice_shard => "Ice Shard",
            .lightning_nova => "Lightning Nova",
            .toxic_flask => "Toxic Flask",
            .dodge => "Dodge",
            .health_potion => "Health Potion",
            .mana_potion => "Mana Potion",
        };
    }

    // One-line description for the loadout screen — what the button does, in plain terms.
    pub fn blurb(s: Skill) [:0]const u8 {
        return switch (s) {
            .melee => "Strike the selected foe up close.",
            .cleave => "Sweep your blade through every foe in front of you.",
            .throwing_knife => "Fling a knife at your target. Quick and free.",
            .firebolt => "Hurl a bolt of fire at your target. Costs mana.",
            .ice_shard => "Loose a freezing shard that chills what it hits. Costs mana.",
            .lightning_nova => "Discharge lightning through every nearby foe. Costs mana.",
            .toxic_flask => "Lob a flask that bursts into a lingering poison cloud. Costs mana.",
            .dodge => "Roll a quick dash with a moment of invulnerability.",
            .health_potion => "Drink to restore health. Uses one from your belt.",
            .mana_potion => "Drink to restore mana. Uses one from your belt.",
        };
    }
};

// ── Reassignable skill bar ────────────────────────────────────────────────────
// The hero's loadout: one skill (or none) per input slot. Slots map to controller
// buttons by index (see input.slotPad): 0=A, 1=X, 2=Y, 3=B, 4=L1, 5=R1; keyboard
// mirrors on the mouse buttons + Q/E/R/F (input.slotKeyDown). A skill lives in AT MOST
// ONE slot — `assign` enforces uniqueness so the palette↔bar mapping can't double-bind.
// EVERY skill (dodge and potions included) is usable ONLY through a bound slot — there
// are no hardcoded shortcuts. Reassignment is the Skills loadout screen (hudx); combat
// fires through these slots (game.zig).
pub const SKILL_SLOTS = 6;

pub const SkillBar = struct {
    slots: [SKILL_SLOTS]?Skill = [_]?Skill{null} ** SKILL_SLOTS,

    /// The out-of-the-box loadout, mapped to the pad's six action buttons:
    /// A empty, X melee, Y firebolt, B dodge, L1 health potion, R1 mana potion. The five
    /// extra skills start unbound — you assign them on the loadout screen. Used by a fresh
    /// hero and as the fallback when no saved bindings exist (or a stale format migrates).
    pub fn default() SkillBar {
        var b = SkillBar{};
        b.assign(1, .melee);
        b.assign(2, .firebolt);
        b.assign(3, .dodge);
        b.assign(4, .health_potion);
        b.assign(5, .mana_potion);
        return b;
    }

    /// Bind `s` (or clear, when null) to `slot`. A skill is unique across the bar, so
    /// it's first removed from any other slot — assigning Firebolt to a new button pulls
    /// it off its old one rather than leaving a phantom copy behind.
    pub fn assign(b: *SkillBar, slot: usize, s: ?Skill) void {
        if (s) |sk| {
            for (&b.slots) |*e| {
                if (e.* == sk) e.* = null;
            }
        }
        b.slots[slot] = s;
    }

    /// The slot holding `s`, or null if it's unbound.
    pub fn slotOf(b: *const SkillBar, s: Skill) ?usize {
        for (b.slots, 0..) |e, i| {
            if (e == s) return i;
        }
        return null;
    }

    /// Cycle `slot` forward (dir=+1) or back (-1) through the skills available to it —
    /// each skill that's free or already here, plus "empty". A skill bound to ANOTHER
    /// slot is skipped, so cycling never steals a binding (uniqueness holds without the
    /// stealing that plain `assign` would do). This is the controller/keyboard analogue
    /// of cycling a slot with the mouse (click / scroll).
    pub fn cycle(b: *SkillBar, slot: usize, dir: i32) void {
        var opts: [Skill.count + 1]?Skill = undefined;
        var n: usize = 0;
        for (Skill.all) |s| {
            const at = b.slotOf(s);
            if (at == null or at.? == slot) {
                opts[n] = s;
                n += 1;
            }
        }
        opts[n] = null; // empty is always reachable
        n += 1;
        var cur: usize = n - 1; // fall back to the empty option if current isn't listed
        for (opts[0..n], 0..) |o, i| {
            if (o == b.slots[slot]) {
                cur = i;
                break;
            }
        }
        const ni = @mod(@as(i32, @intCast(cur)) + dir, @as(i32, @intCast(n)));
        b.slots[slot] = opts[@intCast(ni)];
    }

    // ── Persistence ──
    // The loadout is a player preference, so it survives across runs and app restarts.
    // Format mirrors the map files: a `version:` header then `slotN: token` lines
    // (@tagName tokens, "-" for empty). Load is deliberately LENIENT — a missing or
    // corrupt file falls back to default() rather than erroring, since a bad binding
    // file must never keep the player out of the game.
    //
    // FORMAT 2 added the potions to the bar. FORMAT 3 remapped the slots to the six pad
    // action buttons (A/X/Y/B/L1/R1) — a FORMAT-2 file's five slots meant different
    // buttons, so it migrates to default() rather than binding skills to the wrong keys.
    // A file from any older format is likewise reset.
    pub const FORMAT = 3;

    pub fn save(b: *const SkillBar, path: []const u8) !void {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        var w = f.writer();
        try w.print("version: {d}\n", .{FORMAT});
        for (b.slots, 0..) |e, i| {
            try w.print("slot{d}: {s}\n", .{ i, if (e) |s| @tagName(s) else "-" });
        }
    }

    pub fn load(path: []const u8) SkillBar {
        const f = std.fs.cwd().openFile(path, .{}) catch return default();
        defer f.close();
        var buf: [512]u8 = undefined;
        const n = f.reader().readAll(&buf) catch return default();

        var parsed = SkillBar{};
        var sawVersion = false;
        var sawSlot = false;
        var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "version:")) {
                // Only the current format is trusted; anything else migrates to default().
                const v = std.fmt.parseInt(u32, std.mem.trim(u8, line["version:".len..], " "), 10) catch return default();
                if (v != FORMAT) return default();
                sawVersion = true;
                continue;
            }
            if (!std.mem.startsWith(u8, line, "slot")) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const idx = std.fmt.parseInt(usize, std.mem.trim(u8, line["slot".len..colon], " "), 10) catch continue;
            if (idx >= SKILL_SLOTS) continue;
            parsed.slots[idx] = skillFromToken(std.mem.trim(u8, line[colon + 1 ..], " "));
            sawSlot = true;
        }
        if (!sawVersion or !sawSlot) return default();
        // Rebuild through assign so a hand-edited/corrupt file with a duplicate binding
        // is de-duplicated (uniqueness invariant), not carried through verbatim.
        var clean = SkillBar{};
        for (parsed.slots, 0..) |e, i| {
            if (e) |s| clean.assign(i, s);
        }
        return clean;
    }
};

// Skill for a saved token (@tagName), or null for "-"/unknown.
fn skillFromToken(tok: []const u8) ?Skill {
    inline for (Skill.all) |s| {
        if (std.mem.eql(u8, tok, @tagName(s))) return s;
    }
    return null;
}

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

    // Reassignable loadout (defaults set in newPlayer). Persists across areas.
    bar: SkillBar = .{},

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

    // Per-skill recharge for the five extra skills (indexed by @intFromEnum(Skill)). The
    // core three keep their own timers (atkCD/castCD/rollCD); these entries stay 0 for
    // them. `skillCDMax` is the window each was last set to, so the HUD wipe reads a true
    // fraction even as cast-speed/CDR shrink the live window.
    skillCD: [Skill.count]f32 = [_]f32{0} ** Skill.count,
    skillCDMax: [Skill.count]f32 = [_]f32{0} ** Skill.count,

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
            // Consumables and the attribute-scaled extra skills have no rank.
            else => 1,
        };
    }

    /// Spend one skill point ranking up `s`. False if none are available or `s` isn't
    /// rankable (consumables). The point is spent only once a rank actually increments.
    pub fn allocSkill(p: *Player, s: Skill) bool {
        if (p.skillPoints <= 0) return false;
        switch (s) {
            .melee => p.meleeRank += 1,
            .firebolt => p.fireboltRank += 1,
            .dodge => p.dodgeRank += 1,
            else => return false, // consumables + extra skills aren't rankable
        }
        p.skillPoints -= 1;
        p.recompute();
        return true;
    }

    /// Has the extra skill `s` finished recharging? (Core skills use atkCD/castCD/rollCD.)
    pub fn auxReady(p: *const Player, s: Skill) bool {
        return p.skillCD[@intFromEnum(s)] <= 0;
    }
    /// Fraction of `s`'s recharge still to run (1 = just used → 0 = ready), for the HUD wipe.
    pub fn auxFrac(p: *const Player, s: Skill) f32 {
        const i = @intFromEnum(s);
        return if (p.skillCDMax[i] > 0) clampF(p.skillCD[i] / p.skillCDMax[i], 0, 1) else 0;
    }
    /// Put `s` on a `dur`-second recharge (recording the window for the HUD fraction).
    pub fn startAuxCD(p: *Player, s: Skill, dur: f32) void {
        const i = @intFromEnum(s);
        p.skillCD[i] = dur;
        p.skillCDMax[i] = dur;
    }
    /// Advance every extra-skill recharge one frame.
    pub fn tickSkillCDs(p: *Player, dt: f32) void {
        for (&p.skillCD) |*c| {
            if (c.* > 0) c.* -= dt;
        }
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
        if (p.alive() and stats.isLightStun(landed, p.MaxHP)) p.applyStun(stats.LIGHT_STUN_DUR);
        return landed;
    }

    /// Briefly freeze the hero for `dur` (max with any current stun) and cancel an
    /// in-progress swing so the stun genuinely interrupts. Mirrors Monster.applyStun.
    pub fn applyStun(p: *Player, dur: f32) void {
        p.stunTimer = maxF(p.stunTimer, dur);
        p.swing = 0;
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
        @memset(&p.skillCD, 0); // extra-skill recharges reset like the core three (atk/cast/roll)
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
        return drink(&p.HP, p.MaxHP, &p.HealthPots, POTION_HEAL_FRAC, POTION_HEAL_FLAT);
    }

    pub fn drinkMana(p: *Player) bool {
        return drink(&p.Mana, p.MaxMana, &p.ManaPots, POTION_MANA_FRAC, POTION_MANA_FLAT);
    }
};

// Consume one potion to refill a resource by `max*frac + flat` (capped at max). No-op
// (returns false) with no pots or already full — the shared health/mana restore rule.
fn drink(cur: *f32, max: f32, pots: *i32, frac: f32, flat: f32) bool {
    if (pots.* <= 0 or cur.* >= max) return false;
    pots.* -= 1;
    cur.* = minF(max, cur.* + max * frac + flat);
    return true;
}

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
    // Default loadout (the game applies any persisted bindings over this after spawn).
    p.bar = SkillBar.default();
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
