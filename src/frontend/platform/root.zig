//! Everything that differs between operating systems, and nothing else.
//!
//! The drawing layer, the diff, the input parser and the frame scheduler are
//! all portable, and they stay that way by never asking which OS they are on.
//! Four things genuinely differ and they all live behind this file:
//!
//!   1. Getting hold of the controlling terminal.
//!   2. Putting it into raw mode and putting it back.
//!   3. Finding out it was resized.
//!   4. Converting the real clock to the host's local calendar.
//!
//! The escape sequences are *not* on that list. Windows 10 and later interpret
//! them once the console is asked to, which is step 2's job, so the same bytes
//! drive every platform and the emitter never branches.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sequences = @import("sequences.zig");

const impl = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    else => @import("posix.zig"),
};

pub const Size = @import("types.zig").Size;
pub const LocalTime = @import("types.zig").LocalTime;
pub const localTime = impl.localTime;

/// A terminal that has been put into the state a full screen application
/// needs, and knows how to put it back.
///
/// Leaving a terminal raw with the cursor hidden is the rudest thing a TUI can
/// do, and it outlives the process: the settings belong to the device. Every
/// exit path has to reach `deinit`.
pub const Tty = impl.Tty;

/// Blocks until the terminal changes size.
///
/// A separate object from `Tty` because the two platforms learn about resizes
/// in unrelated ways - one is told, the other has to look - and pretending
/// otherwise would push a Unix-shaped abstraction onto Windows.
pub const ResizeWatcher = impl.ResizeWatcher;

/// Arms terminal restoration for the paths `deinit` cannot reach.
///
/// A panic aborts without running `defer`s, so the client's normal cleanup
/// never happens and the terminal stays raw with the panic message rendered
/// unreadably. On POSIX this hooks the fatal signals; the abort at the end of
/// Zig's panic path is one of them.
pub const installCrashRestore = impl.installCrashRestore;

/// What the crash handler runs: emit `leave_sequence` and restore the saved
/// termios. Exposed so the path is testable; idempotent and a no-op until
/// `installCrashRestore` arms it or after `Tty.deinit` disarms it.
pub const emergencyRestore = impl.emergencyRestore;

/// What a full screen application asks the terminal for on the way in.
///
/// Portable because these are bytes, not syscalls: the console mode set by
/// `Tty.open` is what makes Windows read them.
pub const enter_sequence = sequences.enter;

/// Undone in the reverse order, so a terminal that ignores one of them still
/// ends up with the modes it started with.
pub const leave_sequence = sequences.leave;

/// The host modes needed by a pane that currently owns all input. Mouse and
/// paste modes stay off until telar can encode semantic input from the child's
/// terminal modes. Forwarding either one unconditionally corrupts input for a
/// program that did not request it.
pub const pane_enter_sequence = sequences.pane_enter;

pub const pane_leave_sequence = sequences.pane_leave;

// The contract every platform file owes this one.
//
// A missing method on the *other* platform is otherwise invisible until
// somebody cross compiles, which for a project whose author has one machine
// means until a user reports it. This turns that into a build error on every
// target, because the shapes are checked here rather than at each call site.
comptime {
    if (!@hasDecl(impl, "Tty")) @compileError("platform is missing Tty");
    if (!@hasDecl(impl, "ResizeWatcher")) @compileError("platform is missing ResizeWatcher");

    const T = impl.Tty;
    assertFn(T, "open", fn () anyerror!T);
    assertFn(T, "deinit", fn (*T) void);
    assertFn(T, "size", fn (*const T) Size);
    assertFn(T, "readHandle", fn (*const T) Io.File);
    assertFn(T, "writeHandle", fn (*const T) Io.File);
    assertFn(T, "identity", fn (*const T) anyerror!u64);

    const W = impl.ResizeWatcher;
    assertFn(W, "init", fn (*T) anyerror!W);
    assertFn(W, "deinit", fn (*W) void);
    assertFn(W, "wait", fn (*W, Io) Io.Cancelable!void);

    if (!@hasDecl(impl, "installCrashRestore"))
        @compileError("platform is missing installCrashRestore");
    if (!@hasDecl(impl, "emergencyRestore"))
        @compileError("platform is missing emergencyRestore");
    if (!@hasDecl(impl, "localTime")) @compileError("platform is missing localTime");
    assertFn(impl, "localTime", fn () LocalTime);
}

test "host keyboard disambiguation stays inside the alternate screen" {
    const enter_alternate = std.mem.indexOf(u8, enter_sequence, "\x1b[?1049h").?;
    const push_keyboard = std.mem.indexOf(u8, enter_sequence, "\x1b[>1u").?;
    try std.testing.expect(enter_alternate < push_keyboard);

    const pop_keyboard = std.mem.indexOf(u8, leave_sequence, "\x1b[<u").?;
    const leave_alternate = std.mem.indexOf(u8, leave_sequence, "\x1b[?1049l").?;
    try std.testing.expect(pop_keyboard < leave_alternate);
}

fn assertFn(comptime T: type, comptime name: []const u8, comptime Want: type) void {
    if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " is missing " ++ name);
    const Got = @TypeOf(@field(T, name));
    const got = @typeInfo(Got).@"fn";
    const want = @typeInfo(Want).@"fn";
    if (got.params.len != want.params.len)
        @compileError(@typeName(T) ++ "." ++ name ++ " takes the wrong number of arguments");
    // Return types are compared loosely: an implementation is free to return a
    // narrower error set than `anyerror`, and pinning it here would force every
    // platform to invent the same errors.
    for (got.params, want.params, 0..) |g, w, i| {
        if (g.type != w.type) @compileError(std.fmt.comptimePrint(
            "{s}.{s} argument {d} is {s}, expected {s}",
            .{ @typeName(T), name, i, @typeName(g.type.?), @typeName(w.type.?) },
        ));
    }
}
