//! Byte-at-a-time scanners for terminal streams: where OSC strings end,
//! when typed input submits or cancels a line, and how Kitty graphics
//! commands are framed.

pub const InputScanner = @import("InputScanner.zig");
pub const KittyFramingCounter = @import("KittyFramingCounter.zig");
pub const OscScanner = @import("OscScanner.zig");

test {
    _ = @import("Event.zig");
    _ = @import("InputScanner.zig");
    _ = @import("KittyFramingCounter.zig");
    _ = @import("OscScanner.zig");
    _ = @import("escape.zig");
}
