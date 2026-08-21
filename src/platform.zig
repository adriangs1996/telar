//! Everything that differs between operating systems, and nothing else.
//!
//! The drawing layer, the diff, the input parser and the frame scheduler are
//! all portable, and they stay that way by never asking which OS they are on.
//! Three things genuinely differ and they all live behind this file:
//!
//!   1. Getting hold of the controlling terminal.
//!   2. Putting it into raw mode and putting it back.
//!   3. Finding out it was resized.
//!
//! The escape sequences are *not* on that list. Windows 10 and later interpret
//! them once the console is asked to, which is step 2's job, so the same bytes
//! drive every platform and the emitter never branches.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const impl = switch (builtin.os.tag) {
    .windows => @import("platform/windows.zig"),
    else => @import("platform/posix.zig"),
};

pub const Size = struct { cols: u16, rows: u16 };

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

/// What a full screen application asks the terminal for on the way in.
///
/// Portable because these are bytes, not syscalls: the console mode set by
/// `Tty.open` is what makes Windows read them.
pub const enter_sequence =
    "\x1b[?1049h" ++ // alternate screen, so the scrollback is left alone
    "\x1b[?25l" ++ // hide the cursor
    "\x1b[?1000h" ++ // report button presses
    "\x1b[?1002h" ++ // and drags
    "\x1b[?1003h" ++ // and plain movement
    "\x1b[?1006h" ++ // in the SGR encoding
    "\x1b[?2004h" ++ // bracket pastes, so a newline in one is text not Enter
    "\x1b[2J"; // start from a blank screen

/// Undone in the reverse order, so a terminal that ignores one of them still
/// ends up with the modes it started with.
pub const leave_sequence =
    "\x1b[?2004l" ++
    "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" ++
    "\x1b[?25h" ++
    "\x1b[?1049l";

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
    assertFn(T, "writeHandle", fn (*const T) Io.File);

    const W = impl.ResizeWatcher;
    assertFn(W, "init", fn (*T) anyerror!W);
    assertFn(W, "deinit", fn (*W) void);
    assertFn(W, "wait", fn (*W, Io) Io.Cancelable!void);
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
