//! Owner-only files and directories: a bounded read that refuses anything
//! but a private regular file, an atomic replacement, a lock that
//! serializes read-change-replace cycles, a stat fingerprint for pollers,
//! an owner-checked directory, and the inode fields an ownership check
//! reads, the same on every libc.

const private_file = @import("private_file.zig");

pub const Inode = @import("Inode.zig");
pub const Mode = private_file.Mode;
pub const read = private_file.read;
pub const replace = private_file.replace;
pub const lock = private_file.lock;
pub const fingerprint = private_file.fingerprint;
pub const prepareDirectory = private_file.prepareDirectory;

test {
    _ = @import("private_file.zig");
    _ = @import("Inode.zig");
}
