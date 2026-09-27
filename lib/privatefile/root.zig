//! Owner-only files: a bounded read that refuses anything but a private
//! regular file, an atomic replacement, and a stat fingerprint for pollers.

const private_file = @import("private_file.zig");

pub const Mode = private_file.Mode;
pub const read = private_file.read;
pub const replace = private_file.replace;
pub const fingerprint = private_file.fingerprint;

test {
    _ = @import("private_file.zig");
}
