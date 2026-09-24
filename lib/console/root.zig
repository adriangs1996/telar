//! The controlling terminal on every operating system: raw mode, resize
//! notifications, a fast writer and the escape sequences that drive it.
const builtin = @import("builtin");

pub const Size = @import("Size.zig");
pub const platform = @import("platform.zig");
pub const sequences = @import("sequences.zig");

test {
    _ = @import("platform.zig");
    _ = @import("sequences.zig");
    _ = @import("windows.zig");
    if (builtin.os.tag != .windows) {
        _ = @import("posix.zig");
    }
}
