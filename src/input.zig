const rl = @import("raylib");
const mathx = @import("mathx.zig");
const rumble = @import("rumble.zig");

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

// ── Gameplay predicates (buttons; kbm movement stays in game.zig) ──
pub fn padAttackDown() bool {
    return padDown(.right_face_left); // Square / X
}
pub fn padCastDown() bool {
    return padDown(.right_face_up); // Triangle / Y
}
pub fn padDodgePressed() bool {
    return padPressed(.right_face_right); // Circle / B
}
fn padHealthPotPressed() bool {
    return padPressed(.left_trigger_1); // L1
}
fn padManaPotPressed() bool {
    return padPressed(.right_trigger_1); // R1
}
/// Quaff a health / mana potion. Discrete action (not movement), so it lives here:
/// number keys 1 / 2 on the keyboard, L1 / R1 on the pad.
pub fn healthPotPressed() bool {
    return rl.isKeyPressed(.one) or padHealthPotPressed();
}
pub fn manaPotPressed() bool {
    return rl.isKeyPressed(.two) or padManaPotPressed();
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
