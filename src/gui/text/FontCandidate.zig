//! An installed face a background lookup found for one grapheme: the native
//! match naming the file and the file bytes, which the font set adopts on
//! the render thread or frees with the allocator that read them.
const FontMatch = @import("../native/FontMatch.zig").FontMatch;

match: FontMatch,
bytes: []u8,
