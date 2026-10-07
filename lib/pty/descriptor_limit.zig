//! The soft descriptor limit children start with. A raise never passes
//! `select_descriptor_ceiling`, the FD_SETSIZE of Linux and macOS, so a
//! child started any way, through `std.process.spawn` included, can never
//! open a descriptor that select() cannot hold. A child spawned on a pty
//! also gets back the exact limit the process inherited, between fork and
//! exec.

const std = @import("std");

/// Whether `inherited` holds the limit the process started with. Set once,
/// before any raise, and read by children after fork.
var recorded: std.atomic.Value(bool) = .init(false);

/// FD_SETSIZE on Linux and macOS: descriptors from this one on do not fit
/// the fd_set select() takes.
pub const select_descriptor_ceiling: std.posix.rlim_t = 1024;
// SAFETY: raise stores the inherited limit before publishing recorded; restoreInChild checks recorded before reading it.
var inherited: std.posix.rlimit = undefined;

/// Raises the process's soft descriptor limit toward `wanted`, never past
/// `select_descriptor_ceiling` or the hard limit, after recording the limit
/// it inherited. A limit already higher, or one that cannot be raised, is
/// kept.
///
/// ```zig
/// descriptor_limit.raise(1536);
/// ```
pub fn raise(wanted: std.posix.rlim_t) void {
    var limits = std.posix.getrlimit(.NOFILE) catch return;
    if (!recorded.load(.acquire)) {
        inherited = limits;
        recorded.store(true, .release);
    }

    const target = @min(wanted, select_descriptor_ceiling, limits.max);
    if (limits.cur >= target) {
        return;
    }

    limits.cur = target;
    // Raising this soft limit is optional; failure leaves the kernel's previous limit in effect.
    std.posix.setrlimit(.NOFILE, limits) catch {};
}

/// Gives a freshly forked child the soft limit the process inherited. Only
/// a syscall, so it is safe between fork and exec.
///
/// ```zig
/// descriptor_limit.restoreInChild();
/// ```
pub fn restoreInChild() void {
    if (!recorded.load(.acquire)) {
        return;
    }

    // Failure leaves the bounded parent limit in effect; this post-fork path must not allocate or log before exec.
    std.posix.setrlimit(.NOFILE, inherited) catch {};
}
