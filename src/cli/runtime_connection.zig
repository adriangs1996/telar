//! Discovery and authenticated connection to the local Telar runtime.

const std = @import("std");
const LocalType = @import("telar-core").Local;

pub const native = @cImport({
    @cInclude("sys/stat.h");
});

pub const runtime_start_attempts = 200;
pub const runtime_start_interval_ms = 10;

pub fn resolveEndpoint(environ: std.process.Environ, override: ?[*:0]const u8) !LocalType {
    if (override) |path| {
        return LocalType.explicit(std.mem.span(path));
    }

    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET")) |path| {
        if (path.len != 0) {
            return LocalType.explicit(path);
        }
    }

    // Set by the runtime for every pane child, so agents and scripts running
    // inside Telar address the runtime that owns their pane.
    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET_PATH")) |path| {
        if (path.len != 0) {
            return LocalType.explicit(path);
        }
    }

    if (std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")) |base| {
        if (base.len != 0) {
            return LocalType.managed(base, "telar");
        }
    }

    var directory_name_buffer: [32]u8 = undefined;
    const directory_name = try std.fmt.bufPrint(&directory_name_buffer, "telar-{d}", .{std.c.getuid()});
    if (std.process.Environ.getPosix(environ, "TMPDIR")) |base| {
        if (base.len != 0) {
            return LocalType.managed(base, directory_name);
        }
    }

    return LocalType.managed("/tmp", directory_name);
}

pub fn checkRuntimeDirectoryOwner(owner: std.c.uid_t, current_user: std.c.uid_t) error{WrongOwner}!void {
    if (owner != current_user) {
        return error.WrongOwner;
    }
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

test "the runtime directory must belong to the current user" {
    try checkRuntimeDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkRuntimeDirectoryOwner(0, 1000));
}
