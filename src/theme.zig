const rl = @import("raylib");

const rgba = rl.Color.init;

// Shared semantic UI colors. The two core resources each get ONE definition so the
// orb fill, belt swatch, and world drop all read as the same potion — previously
// these were re-specified with slightly different RGB at every draw site.

// Health (red).
pub const healthColor = rgba(200, 38, 45, 255); // potion / orb fill / drop
pub const healthSocket = rgba(60, 14, 14, 255); // drained orb backing

// Mana (blue).
pub const manaColor = rgba(50, 90, 220, 255);
pub const manaSocket = rgba(16, 22, 60, 255);

// Gold (currency): coin drop, pickup popup, and belt total all read as one color.
pub const goldColor = rgba(255, 215, 80, 255);

// Brass trim: the thin warm liner on HUD sockets, bars, and panels — one metal
// throughout so the interface reads as a single forged kit.
pub const trimColor = rgba(150, 116, 60, 255);
