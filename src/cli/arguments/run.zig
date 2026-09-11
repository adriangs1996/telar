//! Interactive client launch grammar, including the command delimiter.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
pub const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;

pub const RunOptions = @import("RunOptions.zig");

pub fn defaultShell(environ: std.process.Environ) !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return pty.Command.fromArgv(&.{fallback});
    if (configured.len == 0) {
        return pty.Command.fromArgv(&.{fallback});
    }

    return pty.Command.fromArgv(&.{configured.ptr});
}
