const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const monster = @import("monster.zig");

const ground = mathx.ground;

pub const LootKind = enum(u8) { gold, health_potion, mana_potion };

// LootDrop is a pickup on the ground. Walking over it collects it.
pub const LootDrop = struct {
    Kind: LootKind,
    Pos: rl.Vector3,
    Amount: i32 = 0,
    bob: f32 = 0,
};

// Drop-table tuning (all the knobs in one block, like the rest of the repo).
pub const GOLD_CHANCE: f32 = 0.85;
pub const HP_CHANCE: f32 = 0.16;
pub const MANA_CHANCE: f32 = 0.10;
pub const BOSS_HP_CHANCE: f32 = 1.0;
pub const BOSS_MANA_CHANCE: f32 = 0.8;
pub const SCATTER_RADIUS: f32 = 0.8;

// Decides what a slain monster drops, appending into `out`.
pub fn rollLoot(m: *const monster.Monster, rng: *mathx.Rng, out: *std.ArrayList(LootDrop)) void {
    // Gold almost always drops.
    if (m.GoldDrop > 0 and rng.float() < GOLD_CHANCE) {
        const amt = @divTrunc(m.GoldDrop, 2) + rng.intn(m.GoldDrop + 1);
        out.append(.{ .Kind = .gold, .Pos = scatter(m.Pos, rng), .Amount = amt }) catch @panic("oom");
    }
    // Potions drop occasionally; bosses are generous.
    const hpChance: f32 = if (m.boss) BOSS_HP_CHANCE else HP_CHANCE;
    const manaChance: f32 = if (m.boss) BOSS_MANA_CHANCE else MANA_CHANCE;
    if (rng.float() < hpChance) out.append(.{ .Kind = .health_potion, .Pos = scatter(m.Pos, rng), .Amount = 1 }) catch @panic("oom");
    if (rng.float() < manaChance) out.append(.{ .Kind = .mana_potion, .Pos = scatter(m.Pos, rng), .Amount = 1 }) catch @panic("oom");
}

fn scatter(p: rl.Vector3, rng: *mathx.Rng) rl.Vector3 {
    return ground(p.x + (rng.float() * 2 - 1) * SCATTER_RADIUS, p.z + (rng.float() * 2 - 1) * SCATTER_RADIUS);
}
