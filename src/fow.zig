const rl = @import("raylib");
const mathx = @import("mathx.zig");
const state = @import("state.zig");
const lighting = @import("lighting.zig");

// Lightweight "active" fog of war: the hero only sees enemies and loot within
// their light. Purely distance-based (no shader/texture), so it can't black out
// the scene. (fow.go)

// visionRadius is how far the hero sees; it matches the torch pool.
pub const visionRadius = lighting.torchBaseRadius;

// inVision reports whether a world point is within the hero's current sight.
pub fn inVision(g: *state.GameState, p: rl.Vector3) bool {
    return mathx.distXZ(p, g.player.Pos) <= visionRadius + 2.5;
}
