const std = @import("std");
const game = @import("game.zig");
const demo2 = @import("demo2.zig");

// Entry point. Default (no args) launches the game; `--demo2` runs the frozen
// reference demo for side-by-side comparison.
pub fn main() void {
    const alloc = std.heap.c_allocator;
    const argv = std.process.argsAlloc(alloc) catch {
        game.run(false);
        return;
    };
    defer std.process.argsFree(alloc, argv);

    if (argv.len >= 2) {
        const a = argv[1];
        // Frozen reference demo (approved lighting), kept intact for comparison.
        if (std.mem.eql(u8, a, "--demo2")) {
            demo2.run(false);
            return;
        }
        if (std.mem.eql(u8, a, "--demo2shot")) {
            demo2.run(true);
            return;
        }
        // Hidden-window screenshot of the game, for offline visual checks.
        if (std.mem.eql(u8, a, "--gameshot")) {
            game.run(true);
            return;
        }
    }

    game.run(false); // default: the game
}
