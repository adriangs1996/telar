const GlyphSlot = @import("GlyphSlot.zig");

key: u128 = 0,
pending: bool = false,
slot: ?GlyphSlot = null,
