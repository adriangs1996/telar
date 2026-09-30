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

test "the default endpoint ignores the sockets a pane or a user names" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_SOCKET", "/telar.sock");
    try environment.put("TELAR_SOCKET_PATH", "/pane.sock");
    try environment.put("XDG_RUNTIME_DIR", "/run/user/42");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const named = try resolveEndpoint(.{ .block = block }, null);
    const default = try defaultEndpoint(.{ .block = block });

    try std.testing.expectEqualStrings("/telar.sock", named.path());
    try std.testing.expectEqualStrings("/run/user/42/telar/runtime.sock", default.path());
}

test "an explicit runtime endpoint overrides the environment" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_SOCKET", "/environment.sock");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, "/explicit.sock");

    try std.testing.expectEqualStrings("/explicit.sock", endpoint.path());
}

test "runtime endpoint resolution follows environment precedence" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_SOCKET", "/telar.sock");
    try environment.put("XDG_RUNTIME_DIR", "/run/user/42");
    try environment.put("TMPDIR", "/private/tmp");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, null);

    try std.testing.expectEqualStrings("/telar.sock", endpoint.path());
}

test "XDG runtime endpoints use Telar's managed directory" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", "/run/user/42");
    try environment.put("TMPDIR", "/private/tmp");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, null);

    try std.testing.expectEqualStrings("/run/user/42/telar", endpoint.managedDirectory().?);
    try std.testing.expectEqualStrings("/run/user/42/telar/runtime.sock", endpoint.path());
}

test "runtime endpoint falls back to a user-specific temporary directory" {
    const endpoint = try resolveEndpoint(.empty, null);
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "/tmp/telar-{d}/runtime.sock", .{std.c.getuid()});

    try std.testing.expectEqualStrings(expected, endpoint.path());
}
