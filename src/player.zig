const rl = @import("raylib");
const mathx = @import("mathx.zig");

const v3 = mathx.v3;
const lenXZ = mathx.lenXZ;
const minF = mathx.minF;

// Dodge-roll tuning: a short, fast burst with a generous i-frame window — the
// core way to survive deadly, telegraphed attacks.
pub const rollDur = 0.42;
pub const rollSpeed = 17.0;
pub const rollCDMax = 1.05;
pub const rollIframe = 0.34;

// swingDur is the melee swing animation length (seconds).
pub const swingDur = 0.22;

pub const maxPots = 9;

// Player is the hero — an Amazon-ish ranged/melee hybrid.
pub const Player = struct {
    Pos: rl.Vector3 = mathx.zero3,
    Facing: rl.Vector3 = mathx.zero3,
    Radius: f32 = 0,
    Speed: f32 = 0,

    Level: i32 = 0,
    XP: i32 = 0,
    XPNext: i32 = 0,

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
    targetMonster: i32 = -1, // monster id, or -1

    // Combat timers.
    atkCD: f32 = 0,
    atkRate: f32 = 0,
    atkRange: f32 = 0,
    castCD: f32 = 0,

    // Dodge roll.
    rollTimer: f32 = 0,
    rollCD: f32 = 0,
    rollDir: rl.Vector3 = mathx.zero3,
    iframe: f32 = 0,

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

    pub fn levelUp(p: *Player) void {
        p.MaxHP += 22;
        p.MaxMana += 9;
        p.MinDmg += 2.2;
        p.MaxDmg += 3.0;
        p.spellDmg += 4;
        p.hpRegen += 0.25;
        // A level-up fully restores you, Diablo-style.
        p.HP = p.MaxHP;
        p.Mana = p.MaxMana;
    }

    /// Begin a dodge in dir (falling back to facing). False if on cooldown/underway.
    pub fn startRoll(p: *Player, dir_in: rl.Vector3) bool {
        if (p.rollCD > 0 or p.rollTimer > 0 or !p.alive()) return false;
        var dir = dir_in;
        if (lenXZ(dir) < 1e-3) dir = p.Facing;
        if (lenXZ(dir) < 1e-3) dir = v3(0, 0, -1);
        p.rollDir = dir;
        p.Facing = dir;
        p.rollTimer = rollDur;
        p.rollCD = rollCDMax;
        p.iframe = rollIframe;
        // A roll interrupts whatever you were doing.
        p.hasMoveTarget = false;
        p.targetMonster = -1;
        return true;
    }

    pub fn takeDamage(p: *Player, dmg: f32) void {
        p.HP -= dmg;
        if (p.HP < 0) p.HP = 0;
        p.hitFlash = 0.25;
    }

    pub fn regen(p: *Player, dt: f32) void {
        if (p.HP > 0 and p.HP < p.MaxHP) p.HP = minF(p.MaxHP, p.HP + p.hpRegen * dt);
        if (p.Mana < p.MaxMana) p.Mana = minF(p.MaxMana, p.Mana + p.manaRegen * dt);
    }

    pub fn drinkHealth(p: *Player) bool {
        if (p.HealthPots <= 0 or p.HP >= p.MaxHP) return false;
        p.HealthPots -= 1;
        p.HP = minF(p.MaxHP, p.HP + p.MaxHP * 0.55 + 30);
        return true;
    }

    pub fn drinkMana(p: *Player) bool {
        if (p.ManaPots <= 0 or p.Mana >= p.MaxMana) return false;
        p.ManaPots -= 1;
        p.Mana = minF(p.MaxMana, p.Mana + p.MaxMana * 0.6 + 20);
        return true;
    }
};

pub fn newPlayer(pos: rl.Vector3) Player {
    var p = Player{
        .Pos = pos,
        .Facing = v3(0, 0, -1),
        .Radius = 0.55,
        .Speed = 4.6, // deliberate, weighty walk
        .Level = 1,
        .XP = 0,
        .MaxHP = 100,
        .MaxMana = 50,
        .hpRegen = 0.4, // you cannot soak — avoid, don't tank
        .manaRegen = 3.0,
        .MinDmg = 9,
        .MaxDmg = 15,
        .Gold = 0,
        .HealthPots = 4,
        .ManaPots = 2,
        .targetMonster = -1,
        .atkRate = 0.85, // slower, heavier swings
        .atkRange = 2.4,
        .spellCost = 7,
        .spellDmg = 20,
    };
    p.HP = p.MaxHP;
    p.Mana = p.MaxMana;
    p.XPNext = xpForLevel(p.Level);
    return p;
}

// xpForLevel is the XP required to advance FROM the given level.
pub fn xpForLevel(level: i32) i32 {
    return 40 + (level - 1) * 55 + (level - 1) * (level - 1) * 12;
}
