//! Composition of the interactive Telar client process.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const config = @import("config.zig");
const parser = @import("parser.zig");
const plugin = @import("plugin.zig");
const remote = @import("remote.zig");
const runtime_connection = @import("runtime_connection.zig");
const TestEnvironment = @import("test_environment.zig").TestEnvironment;

pub const Io = std.Io;
pub const RunOptions = parser.RunOptions;
const RuntimeConnector = runtime_connection.RuntimeConnector;
pub const max_args = backend.pty.max_args;

/// Connects to the selected runtime, prepares the local client configuration
/// and transfers its owned resources into the frontend client lifecycle.
///
/// ```zig
/// const exit_code = try client.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: RunOptions) !u8 {
    var forward: ?remote.Forward = null;
    defer if (forward) |*owned| owned.stop(init.io);
    if (options.remote) |destination| {
        forward = try remote.establish(init, std.mem.span(destination));
    }

    const connector = try RuntimeConnector.init(init, if (forward) |*owned| owned.localPathZ() else null);
    var connection = if (forward != null)
        try remote.connectForwarded(init, &connector)
    else
        try connector.connectOrStart(.{
            .path = options.config,
            .disabled = options.no_config,
            .profile = options.profile,
            .fresh = options.fresh,
        });
    defer connection.deinit(init.io);

    var launch: Launch = undefined;
    try launch.prepare(.{
        .process = init,
        .options = &options,
        .endpoint = connector.endpointPath(),
        .remote_defaults = if (forward) |*owned| owned.discovery.launchDefaults() else null,
    });
    defer launch.deinit();

    const frontend_options = launch.frontendOptions();
    launch.transferResources();
    return frontend.client.run(init, &connection, frontend_options);
}

const Preparation = @import("ClientPreparation.zig");

const Launch = @import("ClientLaunch.zig");

pub fn supportsHostSharedMemory(environ: std.process.Environ) bool {
    if (environ.getPosix("SSH_CONNECTION") != null) {
        return false;
    }

    const terminal_program = environ.getPosix("TERM_PROGRAM") orelse return false;
    return std.ascii.eqlIgnoreCase(terminal_program, "ghostty");
}

pub fn configuredEditor(environ: std.process.Environ) []const u8 {
    return environ.getPosix("EDITOR") orelse "";
}

test "remote launch uses remote home and shell rather than client paths" {
    var environment = try TestEnvironment.init(&.{.{ "SHELL", "/opt/homebrew/bin/local-shell" }});
    defer environment.deinit();
    const options = try RunOptions.parse(&.{ "--remote", "box" }, .{ .block = environment.block });
    var launch: Launch = .{ .process = undefined, .options = &options, .endpoint = "/forward.sock" };
    try launch.prepareChild(.{ .cwd = "/home/remote-user", .shell = "/bin/remote-shell" });

    try std.testing.expectEqualStrings("/home/remote-user", launch.cwd_buffer[0..launch.cwd_len]);
    try std.testing.expectEqual(@as(usize, 1), launch.argument_count);
    try std.testing.expectEqualStrings("/bin/remote-shell", launch.argument_storage[0]);
}

test "remote launch preserves explicit commands while keeping the remote home" {
    const options = try RunOptions.parse(&.{ "--remote", "box", "/bin/bash", "-l" }, .empty);
    var launch: Launch = .{ .process = undefined, .options = &options, .endpoint = "/forward.sock" };
    try launch.prepareChild(.{ .cwd = "/home/remote-user", .shell = "/bin/remote-shell" });

    try std.testing.expectEqualStrings("/home/remote-user", launch.cwd_buffer[0..launch.cwd_len]);
    try std.testing.expectEqual(@as(usize, 2), launch.argument_count);
    try std.testing.expectEqualStrings("/bin/bash", launch.argument_storage[0]);
    try std.testing.expectEqualStrings("-l", launch.argument_storage[1]);
}

test "local Ghostty clients may use host shared memory" {
    var environment = try TestEnvironment.init(&.{.{ "TERM_PROGRAM", "Ghostty" }});
    defer environment.deinit();

    try std.testing.expect(supportsHostSharedMemory(.{ .block = environment.block }));
}

test "SSH clients never use host shared memory" {
    var environment = try TestEnvironment.init(&.{
        .{ "TERM_PROGRAM", "ghostty" },
        .{ "SSH_CONNECTION", "host 22 host 22" },
    });
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
}

test "other terminals do not use Ghostty shared memory" {
    var environment = try TestEnvironment.init(&.{.{ "TERM_PROGRAM", "iTerm.app" }});
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
    try std.testing.expect(!supportsHostSharedMemory(.empty));
}

test "the client snapshots EDITOR without inventing a fallback" {
    var environment = try TestEnvironment.init(&.{.{ "EDITOR", "/usr/bin/nvim" }});
    defer environment.deinit();

    try std.testing.expectEqualStrings(
        "/usr/bin/nvim",
        configuredEditor(.{ .block = environment.block }),
    );
    try std.testing.expectEqualStrings("", configuredEditor(.empty));
}
