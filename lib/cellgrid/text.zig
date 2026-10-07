//! How many columns a string occupies.
//!
//! The question that quietly sinks hand rolled terminal UIs, and the reason it
//! is a file of its own: the answer must come from one place, because a
//! measurement and a draw that consult different tables disagree by one column
//! and keep going.
//!
//! Which table answers is a build-time choice. The default is the emulator that
//! renders the agents' own output, since that is the only answer guaranteed to
//! match what appears on screen.

const GraphemeIterator = @import("GraphemeIterator.zig");

pub fn measure(text: []const u8) u16 {
    var total: u16 = 0;
    var it: GraphemeIterator = .{ .bytes = text };
    while (it.next()) |cluster| total += cluster.width;
    return total;
}

/// C0 controls, DEL and C1 controls: the codepoints a terminal interprets
/// instead of drawing.
pub fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
