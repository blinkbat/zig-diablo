const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

// Controller rumble.
//
// The game builds raylib on its GLFW desktop backend, where raylib's own
// SetGamepadVibration is a no-op stub — so on Windows we drive XInput directly. We
// resolve XInputSetState at runtime out of whichever xinput DLL is present (loaded once,
// cached), which sidesteps import-library/ABI concerns and keeps build.zig untouched.
// On other platforms we fall back to raylib's API (which does the right thing when the
// SDL backend is selected, and is a harmless no-op otherwise).
//
// Every rumble is expressed as an `Event`: a peak level for each of the two motors plus
// a duration. Motors fade out linearly over that duration, and overlapping events blend
// via a "strongest wins" rule so a big hit takes over a lingering buzz without a weak
// tick ever cutting a strong one short.

// XInput exposes a low-frequency ("heavy") motor and a high-frequency ("sharp buzz")
// motor. Actions the player performs lean on the buzz motor; impacts the player suffers
// lean on the heavy motor; death swells both.

// The controller we drive: input polling (game.zig) and this module's XInput calls
// must target the SAME physical pad, so both read this one index.
pub const PAD = 0;

pub const Event = struct { low: f32 = 0, high: f32 = 0, dur: f32 = 0 };

pub const attack_hit = Event{ .low = 0.25, .high = 0.45, .dur = 0.12 }; // your melee lands
pub const crit_hit = Event{ .low = 0.55, .high = 0.70, .dur = 0.18 }; // a crit lands
pub const cast = Event{ .low = 0.12, .high = 0.30, .dur = 0.10 }; // firebolt cast
pub const hurt = Event{ .low = 0.60, .high = 0.35, .dur = 0.25 }; // you take a hit
pub const death = Event{ .low = 1.00, .high = 0.60, .dur = 0.70 }; // you die
pub const kill = Event{ .low = 0.30, .high = 0.18, .dur = 0.12 }; // you slay a foe
pub const gas_tick = Event{ .low = 0.35, .high = 0.10, .dur = 0.16 }; // choking in miasma
pub const dodge = Event{ .low = 0.18, .high = 0.40, .dur = 0.10 }; // dodge roll
pub const level_up = Event{ .low = 0.40, .high = 0.60, .dur = 0.40 }; // level up

// One motor's fading envelope: replay `peak` at t=dur and ramp to 0 at t=0.
const Motor = struct {
    peak: f32 = 0,
    t: f32 = 0,
    dur: f32 = 0,

    fn level(m: Motor) f32 {
        if (m.dur <= 0 or m.t <= 0) return 0;
        return m.peak * (m.t / m.dur);
    }
    // A new pulse takes over only if it is at least as strong, right now, as whatever is
    // still playing — so a fresh big impact overrides a fading buzz, but a small tick
    // never truncates a bigger event mid-fade.
    fn pulse(m: *Motor, peak: f32, dur: f32) void {
        if (dur <= 0) return;
        if (peak >= m.level()) {
            m.peak = peak;
            m.dur = dur;
            m.t = dur;
        }
    }
    fn tick(m: *Motor, dt: f32) void {
        if (m.t > 0) m.t -= dt;
    }
};

pub const Rumble = struct {
    low: Motor = .{},
    high: Motor = .{},

    pub fn play(self: *Rumble, e: Event) void {
        self.low.pulse(e.low, e.dur);
        self.high.pulse(e.high, e.dur);
    }

    // Advance the envelopes by dt and command the motors. `active` gates output: pass
    // false when there's no controller or the game is paused so the grip goes silent
    // while the envelopes still decay in the background.
    pub fn update(self: *Rumble, dt: f32, active: bool) void {
        self.low.tick(dt);
        self.high.tick(dt);
        setMotors(if (active) self.low.level() else 0, if (active) self.high.level() else 0);
    }

    // Cut all vibration immediately (on quit, so a motor never latches on after exit).
    pub fn stop(self: *Rumble) void {
        self.low = .{};
        self.high = .{};
        setMotors(0, 0);
    }
};

fn setMotors(low: f32, high: f32) void {
    const l = std.math.clamp(low, 0, 1);
    const h = std.math.clamp(high, 0, 1);
    if (builtin.os.tag == .windows) {
        win.set(l, h);
    } else {
        // Best effort on non-Windows: works under raylib's SDL backend, no-op under GLFW.
        rl.setGamepadVibration(PAD, l, h, 0.1);
    }
}

// Windows / XInput backend. Resolved lazily from the first xinput DLL that loads.
const win = struct {
    const WINAPI = std.os.windows.WINAPI;
    const XINPUT_VIBRATION = extern struct { wLeftMotor: u16 = 0, wRightMotor: u16 = 0 };
    const SetStateFn = *const fn (dwUserIndex: u32, pVibration: *XINPUT_VIBRATION) callconv(WINAPI) u32;

    var resolved = false;
    var func: ?SetStateFn = null;

    fn resolve() ?SetStateFn {
        if (resolved) return func;
        resolved = true;
        // Newest first; xinput9_1_0 ships on every Windows since Vista as the fallback.
        for ([_][]const u8{ "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll" }) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(SetStateFn, "XInputSetState")) |f| {
                func = f; // keep `lib` loaded for the process lifetime (never FreeLibrary)
                break;
            }
        }
        return func;
    }

    fn set(l: f32, h: f32) void {
        const f = resolve() orelse return;
        var vib = XINPUT_VIBRATION{
            .wLeftMotor = @intFromFloat(l * 65535.0),
            .wRightMotor = @intFromFloat(h * 65535.0),
        };
        _ = f(PAD, &vib); // the first controller (rumble.PAD), matching game.zig's input polling
    }
};
