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

// rollLoot decides what (if anything) a slain monster drops, appending to `out`.
// (Go returned a slice; here we append directly into the game's loot list.)
pub fn rollLoot(m: *const monster.Monster, rng: *mathx.Rng, out: *std.ArrayList(LootDrop)) void {
    // Gold almost always drops.
    if (m.GoldDrop > 0 and rng.float() < 0.85) {
        const amt = @divTrunc(m.GoldDrop, 2) + rng.intn(m.GoldDrop + 1);
        out.append(.{ .Kind = .gold, .Pos = scatter(m.Pos, rng), .Amount = amt }) catch @panic("oom");
    }
    // Potions drop occasionally; bosses are generous.
    var hpChance: f32 = 0.16;
    var manaChance: f32 = 0.10;
    if (m.boss) {
        hpChance = 1.0;
        manaChance = 0.8;
    }
    if (rng.float() < hpChance) out.append(.{ .Kind = .health_potion, .Pos = scatter(m.Pos, rng), .Amount = 1 }) catch @panic("oom");
    if (rng.float() < manaChance) out.append(.{ .Kind = .mana_potion, .Pos = scatter(m.Pos, rng), .Amount = 1 }) catch @panic("oom");
}

fn scatter(p: rl.Vector3, rng: *mathx.Rng) rl.Vector3 {
    return ground(p.x + (rng.float() * 2 - 1) * 0.8, p.z + (rng.float() * 2 - 1) * 0.8);
}
