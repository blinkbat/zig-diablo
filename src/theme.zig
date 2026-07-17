const rl = @import("raylib");

const rgba = rl.Color.init;

// Shared semantic UI colors: one definition per concept so every draw site (orb fill,
// belt swatch, world drop) reads as the same thing.

// Health (red).
pub const healthColor = rgba(200, 38, 45, 255); // potion / orb fill / drop
pub const healthSocket = rgba(60, 14, 14, 255); // drained orb backing

// Mana (blue).
pub const manaColor = rgba(50, 90, 220, 255);
pub const manaSocket = rgba(16, 22, 60, 255);

// Gold (currency): coin drop, pickup popup, belt total.
pub const goldColor = rgba(255, 215, 80, 255);

// Cork: potion-flask stopper — belt icon and world flask share one tone.
pub const corkColor = rgba(150, 112, 70, 255);

// Brass trim: the warm liner on HUD sockets, bars, and panels — one metal throughout.
pub const trimColor = rgba(150, 116, 60, 255);

// Ink: near-black backing behind pills/bars/plaques (used with withAlpha per site).
pub const ink = rgba(8, 6, 5, 255);

// Oiled walnut: panel-slab wood, lit top edge falling to the dark tone.
pub const woodDark = rgba(28, 17, 10, 255);
pub const woodLight = rgba(50, 32, 17, 255);

// Waxed hardwood molding: the frame band between iron stroke and brass liner,
// with its varnish highlight.
pub const woodMid = rgba(84, 55, 32, 255);
pub const woodBevel = rgba(138, 96, 58, 255);

// Cold iron: heavy frame bands, corner plates, rivet domes (brass rides inside it).
pub const ironDark = rgba(23, 19, 16, 255);
pub const ironLight = rgba(66, 58, 47, 255);

// Muted parchment label text: captions, stepper/field labels (alpha varies via withAlpha).
pub const labelColor = rgba(200, 190, 172, 255);

// Bright brass highlight: active button text, latched borders, caret, minimap square.
pub const highlightColor = rgba(255, 235, 190, 255);

// Warm parchment value text: stepper readouts, focused field text — brighter than labelColor.
pub const valueColor = rgba(255, 240, 205, 255);

// Panel/modal title text (small-caps captions, topbar map name).
pub const titleColor = rgba(255, 230, 190, 255);

// The void behind the arena: main-pass clear color in game and editor. Kept a hair
// above black (and faintly cold) so the arena's true blacks still read darker than it.
pub const voidColor = rgba(9, 9, 13, 255);
