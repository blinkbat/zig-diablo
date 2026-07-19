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

// A UI surface that closes on a pad button (B cancel, A confirm) leaves that button
// HELD into the next gameplay frame, where slotPadDown would instantly fire whatever
// skill rides it (B = dodge on the default bar). A swallowed slot stays dead until
// its button is physically released.
var slotSwallow = [_]bool{false} ** playermod.SKILL_SLOTS;

/// Call when a UI surface closes into gameplay on a pad press.
pub fn swallowHeldSlots() void {
    for (&slotSwallow, 0..) |*s, i| s.* = padDown(slotPadButton(slotPad[i]));
}

/// Is this slot's controller button held this frame? Held (not edge) so a combat skill
/// auto-repeats under its cooldown. `slotPadPressed` is the down-edge, for consumables.
pub fn slotPadDown(slot: usize) bool {
    const down = padDown(slotPadButton(slotPad[slot]));
    if (slotSwallow[slot]) {
        if (down) return false;
        slotSwallow[slot] = false;
    }
    return down;
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
// Edge-triggered via the d-pad (raylib debounces it) + arrows/WASD, PLUS the left stick.
// The stick is the movement control in play, but menus freeze the world and never run the
// gameplay branch, so borrowing it here can't clash with steering. Because the stick is
// analog it has no built-in press edge, so `stickNavEdge` synthesizes one (with hold-to-
// repeat); the d-pad and keys keep their own native edges.
pub fn navUp() bool {
    return rl.isKeyPressed(.up) or rl.isKeyPressed(.w) or padPressed(.left_face_up) or stickNavEdge(.up);
}
pub fn navDown() bool {
    return rl.isKeyPressed(.down) or rl.isKeyPressed(.s) or padPressed(.left_face_down) or stickNavEdge(.down);
}
pub fn navLeft() bool {
    return rl.isKeyPressed(.left) or rl.isKeyPressed(.a) or padPressed(.left_face_left) or stickNavEdge(.left);
}
pub fn navRight() bool {
    return rl.isKeyPressed(.right) or rl.isKeyPressed(.d) or padPressed(.left_face_right) or stickNavEdge(.right);
}

// Discrete menu steps from the analog left stick. It fires once when the stick crosses
// past NAV_ENGAGE, then hold-to-repeat kicks in (a slow first repeat, then faster) so a
// long list scrolls without a wall of flicks; it must fall back under NAV_RELEASE to
// re-arm, and the gap between the two thresholds (hysteresis) swallows jitter at the edge.
// Each direction latches independently, so a diagonal can't cross-fire. State is module
// scope because these predicates are the only per-frame stick reads on a menu surface.
const NAV_ENGAGE = 0.5; // tilt past this to register a step
const NAV_RELEASE = 0.35; // must fall back under this to arm the next step
const NAV_REPEAT_DELAY = 0.40; // held this long before the first auto-repeat
const NAV_REPEAT_RATE = 0.11; // then one step every this many seconds

const NavDir = enum(usize) { up, down, left, right };
const NAV_DIRS = @typeInfo(NavDir).@"enum".fields.len; // pins the per-dir arrays to the enum
var navArmed = [_]bool{true} ** NAV_DIRS; // ready to fire (stick is below the release threshold)
var navNextRepeat = [_]f64{0} ** NAV_DIRS;

// Signed tilt toward `dir` (matches stickXZ: up = -Y, left = -X). 0 without a controller.
fn stickAmount(dir: NavDir) f32 {
    if (!padAvail()) return 0;
    const x = rl.getGamepadAxisMovement(PAD, .left_x);
    const y = rl.getGamepadAxisMovement(PAD, .left_y);
    return switch (dir) {
        .up => -y,
        .down => y,
        .left => -x,
        .right => x,
    };
}

fn stickNavEdge(dir: NavDir) bool {
    const i = @intFromEnum(dir);
    return navTick(stickAmount(dir), rl.getTime(), &navArmed[i], &navNextRepeat[i]);
}

// The edge/repeat state machine, kept raylib-free so the timing logic is testable in
// isolation (the rl axis/time reads are the only untested part — trivial pass-throughs).
// `amt` = signed tilt toward the direction, `now` = seconds; mutates the caller's latch.
fn navTick(amt: f32, now: f64, armed: *bool, nextRepeat: *f64) bool {
    if (amt < NAV_RELEASE) {
        armed.* = true; // fell back toward center — arm the next step
        return false;
    }
    if (amt < NAV_ENGAGE) return false; // hysteresis band: neither fire nor re-arm
    if (armed.*) {
        armed.* = false;
        nextRepeat.* = now + NAV_REPEAT_DELAY;
        return true; // initial engage edge
    }
    if (now >= nextRepeat.*) {
        nextRepeat.* = now + NAV_REPEAT_RATE;
        return true; // auto-repeat while held
    }
    return false;
}

test "navTick: engage edge, hysteresis, hold-to-repeat, re-arm" {
    const t = std.testing;
    var armed = true;
    var next: f64 = 0;
    // Below release: no fire, stays armed.
    try t.expect(!navTick(0.1, 0.0, &armed, &next));
    try t.expect(armed);
    // Hysteresis band (release <= amt < engage): no fire, no re-arm change.
    try t.expect(!navTick(0.4, 0.0, &armed, &next));
    try t.expect(armed);
    // Cross engage: single fire, disarms, schedules first repeat after the delay.
    try t.expect(navTick(0.9, 1.0, &armed, &next));
    try t.expect(!armed);
    // Held past engage but before the repeat delay: no fire.
    try t.expect(!navTick(0.9, 1.2, &armed, &next));
    // Still held, delay elapsed: auto-repeat fires and reschedules at the faster rate.
    try t.expect(navTick(0.9, 1.0 + NAV_REPEAT_DELAY, &armed, &next));
    try t.expect(!navTick(0.9, 1.0 + NAV_REPEAT_DELAY + 0.05, &armed, &next));
    try t.expect(navTick(0.9, 1.0 + NAV_REPEAT_DELAY + NAV_REPEAT_RATE, &armed, &next));
    // Fall back under release: re-arms, so the next engage is a fresh single edge.
    try t.expect(!navTick(0.2, 5.0, &armed, &next));
    try t.expect(armed);
    try t.expect(navTick(0.9, 6.0, &armed, &next));
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
/// Interact / talk to the nearest NPC. Keyboard T (mnemonic "talk"); on the pad, D-pad Up.
/// Both are free in play — the six skill slots own the face buttons, bumpers, Q/E/R/F, and
/// the mouse — so this can't shadow a combat input.
pub fn interactPressed() bool {
    return rl.isKeyPressed(.t) or padPressed(.left_face_up);
}
/// Restart from the death screen.
pub fn restartPressed(altHeld: bool) bool {
    return rl.isKeyPressed(.r) or confirm(altHeld);
}

/// Open/close the character stat sheet: C on keyboard, Select/View on the pad.
pub fn sheetTogglePressed() bool {
    return rl.isKeyPressed(.c) or padPressed(.middle_left);
}
