//! Byte-at-a-time scanners for terminal streams: where OSC strings end,
//! when typed input submits or cancels a line, how Kitty graphics commands
//! are framed and where each one ends.

pub const ApcFraming = @import("ApcFraming.zig");
pub const ApcTransition = @import("ApcTransition.zig").ApcTransition;
pub const InputScanner = @import("InputScanner.zig");
pub const KittyCommand = @import("KittyCommand.zig");
pub const KittyCommandScanner = @import("KittyCommandScanner.zig");
pub const KittyFramingCounter = @import("KittyFramingCounter.zig");
pub const OscScanner = @import("OscScanner.zig");

test {
    _ = @import("ApcFraming.zig");
    _ = @import("Event.zig");
    _ = @import("InputScanner.zig");
    _ = @import("KittyCommandScanner.zig");
    _ = @import("KittyFramingCounter.zig");
    _ = @import("OscScanner.zig");
    _ = @import("escape.zig");
}
