//! Discovery and authenticated connection to the local Telar runtime.

const localsocket = @import("localsocket");
const std = @import("std");

/// How long a client waits, 10 s in all, for a runtime it started to listen:
/// a cold start that restores a large history from a slow disk takes
/// seconds.
pub const runtime_start_attempts = 1000;
pub const runtime_start_interval_ms = 10;

pub fn resolveEndpoint(environ: std.process.Environ, override: ?[*:0]const u8) !localsocket.Local {
    if (override) |path| {
        return localsocket.Local.explicit(std.mem.span(path));
    }

    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET")) |path| {
        if (path.len != 0) {
            return localsocket.Local.explicit(path);
        }
    }

    // Set by the runtime for every pane child, so agents and scripts running
    // inside Telar address the runtime that owns their pane.
    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET_PATH")) |path| {
        if (path.len != 0) {
            return localsocket.Local.explicit(path);
        }
    }

    return defaultEndpoint(environ);
}

/// The endpoint of the runtime nothing names explicitly: the socket in
/// Telar's managed directory, which the user's own runtime always listens on.
/// A runtime compares its socket against it to know it is that one.
///
/// ```zig
/// const own = try runtime_connection.defaultEndpoint(environ);
/// ```
pub fn defaultEndpoint(environ: std.process.Environ) !localsocket.Local {
    if (std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")) |base| {
        if (base.len != 0) {
            return localsocket.Local.managed(base, "telar");
        }
    }

    var directory_name_buffer: [32]u8 = undefined;
    const directory_name = try std.fmt.bufPrint(&directory_name_buffer, "telar-{d}", .{std.c.getuid()});
    if (std.process.Environ.getPosix(environ, "TMPDIR")) |base| {
        if (base.len != 0) {
            return localsocket.Local.managed(base, directory_name);
        }
    }

    return localsocket.Local.managed("/tmp", directory_name);
}
