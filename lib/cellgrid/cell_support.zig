//! What one screen position holds.
//!
//! Separate from the buffer because these types cross every boundary in the
//! library - the diff compares them, the blit produces them, the selection
//! reads them - while the buffer that stores them is an implementation detail
//! any of those could do without.

pub const Color = @import("Color.zig").Color;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
