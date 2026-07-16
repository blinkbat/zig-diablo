const std = @import("std");
const rl = @import("raylib");
const mathx = @import("mathx.zig");
const rumble = @import("rumble.zig");
const playermod = @import("player.zig");

const v3 = mathx.v3;
const lenXZ = mathx.lenXZ;
const dirXZ = mathx.dirXZ;

// The ONE place the control scheme lives: every non-editor surface reads input
// through these semantic predicates, so the keyboard↔gamepad mapping is defined once.
// (The editor is KBM-only and polls raw — the sole exception.)
//
// PS face-button naming (raylib's right_face_* are the diamond):
//   right_face_down  = Cross  / A     → confirm
//   right_face_right = Circle / B     → cancel/back (and, in play, dodge)
//   right_face_left  = Square / X     → attack (in play)
//   right_face_up    = Triangle / Y   → cast (in play)
//   middle_left      = Select/View/Share → open the stat sheet
//   middle_right     = Start          → pause / menu-confirm

pub const PAD = rumble.PAD; // first connected controller (shared with the rumble backend)
pub const STICK_DEADZONE = 0.25; // ignore small stick drift
pub const AIM_REACH = 6.0; // how far ahead the right stick projects the aim point

fn padAvail() bool {
    return rl.isGamepadAvailable(PAD);
}
fn padDown(btn: rl.GamepadButton) bool {
    return padAvail() and rl.isGamepadButtonDown(PAD, btn);
}
fn padPressed(btn: rl.GamepadButton) bool {
    return padAvail() and rl.isGamepadButtonPressed(PAD, btn);
}

/// Stick as a unit XZ direction (stick up = -Z = forward, matching camera/WASD).
/// Zero inside the deadzone.
pub fn stickXZ(axisX: rl.GamepadAxis, axisY: rl.GamepadAxis) rl.Vector3 {
    const v = v3(rl.getGamepadAxisMovement(PAD, axisX), 0, rl.getGamepadAxisMovement(PAD, axisY));
    if (lenXZ(v) < STICK_DEADZONE) return mathx.zero3;
    return dirXZ(mathx.zero3, v); // normalize to a unit heading
}

// ── Skill bar ──
// Controller is the primary input, so every slot has a REAL pad button. The bar is the
// six action buttons: the four right-hand face buttons (A/X/Y/B) plus both shoulders
// (L1/R1) — the left stick moves and the right stick aims, so nothing here clashes with
// steering. This is the ONE source for the mapping: game.zig fires slots through
// slotPadDown and the HUD draws each slot's glyph from slotPad, so the drawn button
// can't lie about what fires it. Enum order is slot order; the assert pins the count.
pub const SlotPad = enum { face_a, face_x, face_y, face_b, l1, r1 };
pub const slotPad = [playermod.SKILL_SLOTS]SlotPad{ .face_a, .face_x, .face_y, .face_b, .l1, .r1 };
comptime {
    std.debug.assert(slotPad.len == playermod.SKILL_SLOTS);
}

fn slotPadButton(sp: SlotPad) rl.GamepadButton {
    return switch (sp) {
        .face_a => .right_face_down, // Cross / A
        .face_x => .right_face_left, // Square / X
        .face_y => .right_face_up, // Triangle / Y
        .face_b => .right_face_right, // Circle / B
        .l1 => .left_trigger_1, // L1
        .r1 => .right_trigger_1, // R1
    };
}

/// Is this slot's controller button held this frame? Held (not edge) so a combat skill
/// auto-repeats under its cooldown. `slotPadPressed` is the down-edge, for consumables.
pub fn slotPadDown(slot: usize) bool {
    return padDown(slotPadButton(slotPad[slot]));
}
pub fn slotPadPressed(slot: usize) bool {
    return padPressed(slotPadButton(slotPad[slot]));
}

// Keyboard mirror of the slots (secondary to the pad), parallel to `slotPad` and pinned
// to the same slot count. null = no key (slots 0/1 are the mouse buttons in game.zig).
// Keys avoid WASD/arrows (movement): slots 2-5 = Q/E/R/F. `slotKeyDown` is held;
// `slotKeyPressed` is the edge, for potions.
pub const slotKey = [playermod.SKILL_SLOTS]?rl.KeyboardKey{ null, null, .q, .e, .r, .f };
pub fn slotKeyDown(slot: usize) bool {
    return if (slotKey[slot]) |k| rl.isKeyDown(k) else false;
}
pub fn slotKeyPressed(slot: usize) bool {
    return if (slotKey[slot]) |k| rl.isKeyPressed(k) else false;
}

// Jump straight to the Skills tab of the character screen (keyboard convenience).
pub fn skillsShortcutPressed() bool {
    return rl.isKeyPressed(.k);
}

// Switch character-screen tab (Stats <-> Skills): Tab on the keyboard, either shoulder
// (L1/R1) on the pad. Only read while the screen is open, so it doesn't clash with the
// in-play potion binding on L1/R1.
pub fn charTabTogglePressed() bool {
    return rl.isKeyPressed(.tab) or padPressed(.left_trigger_1) or padPressed(.right_trigger_1);
}

// ── Menu / UI navigation (keyboard + gamepad) ──
// Edge-triggered via the d-pad (raylib debounces it) + arrows/WASD. The left stick
// is reserved for gameplay movement, so menus use the d-pad (no repeat-state to track).
pub fn navUp() bool {
    return rl.isKeyPressed(.up) or rl.isKeyPressed(.w) or padPressed(.left_face_up);
}
pub fn navDown() bool {
    return rl.isKeyPressed(.down) or rl.isKeyPressed(.s) or padPressed(.left_face_down);
}
pub fn navLeft() bool {
    return rl.isKeyPressed(.left) or rl.isKeyPressed(.a) or padPressed(.left_face_left);
}
pub fn navRight() bool {
    return rl.isKeyPressed(.right) or rl.isKeyPressed(.d) or padPressed(.left_face_right);
}

/// Confirm/activate. `altHeld` guards Alt+Enter (fullscreen) from doubling as confirm.
pub fn confirm(altHeld: bool) bool {
    return (rl.isKeyPressed(.enter) and !altHeld) or rl.isKeyPressed(.space) or
        padPressed(.right_face_down) or startPressed();
}
/// Cancel / back out one level.
pub fn cancel() bool {
    return rl.isKeyPressed(.escape) or padPressed(.right_face_right);
}
/// Start button (guarded by controller presence): pause / menu-confirm.
pub fn startPressed() bool {
    return padPressed(.middle_right);
}
/// Restart from the death screen.
pub fn restartPressed(altHeld: bool) bool {
    return rl.isKeyPressed(.r) or confirm(altHeld);
}

/// Open/close the character stat sheet: C on keyboard, Select/View on the pad.
pub fn sheetTogglePressed() bool {
    return rl.isKeyPressed(.c) or padPressed(.middle_left);
}
