//! Interactive client launch grammar, including the command delimiter.

const pty = @import("pty");
const std = @import("std");

pub fn defaultShell(environ: std.process.Environ) !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return pty.Command.fromArgv(&.{fallback});
    if (configured.len == 0) {
        return pty.Command.fromArgv(&.{fallback});
    }

    return pty.Command.fromArgv(&.{configured.ptr});
}
