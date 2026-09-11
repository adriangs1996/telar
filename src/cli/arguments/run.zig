//! Interactive client launch grammar, including the command delimiter.

const std = @import("std");
const CommandType = @import("telar-backend").Command;

pub fn defaultShell(environ: std.process.Environ) !CommandType {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return CommandType.fromArgv(&.{fallback});
    if (configured.len == 0) {
        return CommandType.fromArgv(&.{fallback});
    }

    return CommandType.fromArgv(&.{configured.ptr});
}
