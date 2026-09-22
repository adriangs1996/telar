//! Interactive client launch grammar, including the command delimiter.

const backend = @import("telar-backend");
const std = @import("std");

pub fn defaultShell(environ: std.process.Environ) !backend.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return backend.Command.fromArgv(&.{fallback});
    if (configured.len == 0) {
        return backend.Command.fromArgv(&.{fallback});
    }

    return backend.Command.fromArgv(&.{configured.ptr});
}
