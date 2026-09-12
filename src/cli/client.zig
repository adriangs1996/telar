//! Composition of the interactive Telar client process.

const std = @import("std");
const builtin = @import("builtin");
const RunOptions = @import("arguments/RunOptions.zig");
const OptionsType = @import("telar-client").Options;
const SocketChannelType = @import("telar-core").SocketChannel;
const ForwardType = @import("Forward.zig");
const remote = @import("remote.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const ClientLaunch = @import("ClientLaunch.zig");
const ClientRunRun = @import("telar-frontend").ClientRun;
const TestEnvironment = @import("TestEnvironment.zig");

/// Connects to the selected runtime, prepares the local client configuration
/// and transfers its owned resources into the frontend client lifecycle.
///
/// ```zig
/// const exit_code = try client.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: RunOptions) !u8 {
    return launch(init, options, ClientRunRun);
}

/// The same runtime connection and configuration as `run`, presented by the
/// native window instead of the host terminal.
///
/// ```zig
/// const exit_code = try client.runNative(process_init, options);
/// ```
pub fn runNative(init: std.process.Init, options: RunOptions) !u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        std.debug.print("telar gui: the native client is only built on macOS and Linux\n", .{});
        return error.UnsupportedPlatform;
    }

    return launch(init, options, @import("telar-gui").run);
}

/// One presentation adapter's entrypoint: it adopts the resources `Options`
/// carries and runs until the user leaves.
pub const Adapter = *const fn (std.process.Init, *SocketChannelType, OptionsType) anyerror!u8;

fn launch(init: std.process.Init, options: RunOptions, adapter: Adapter) !u8 {
    var forward: ?ForwardType = null;
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

    var prepared: ClientLaunch = undefined;
    try prepared.prepare(.{
        .process = init,
        .options = &options,
        .endpoint = connector.endpointPath(),
        .remote_defaults = if (forward) |*owned| owned.discovery.launchDefaults() else null,
    });
    defer prepared.deinit();

    const frontend_options = prepared.frontendOptions();
    prepared.transferResources();
    return adapter(init, &connection, frontend_options);
}

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
    var environment = try TestEnvironment.init(&.{.{ .name = "SHELL", .value = "/opt/homebrew/bin/local-shell" }});
    defer environment.deinit();
    const options = try RunOptions.parse(&.{ "--remote", "box" }, .{ .block = environment.block });
    var prepared: ClientLaunch = .{ .process = undefined, .options = &options, .endpoint = "/forward.sock" };
    try prepared.prepareChild(.{ .cwd = "/home/remote-user", .shell = "/bin/remote-shell" });

    try std.testing.expectEqualStrings("/home/remote-user", prepared.cwd_buffer[0..prepared.cwd_len]);
    try std.testing.expectEqual(@as(usize, 1), prepared.argument_count);
    try std.testing.expectEqualStrings("/bin/remote-shell", prepared.argument_storage[0]);
}

test "remote launch preserves explicit commands while keeping the remote home" {
    const options = try RunOptions.parse(&.{ "--remote", "box", "/bin/bash", "-l" }, .empty);
    var prepared: ClientLaunch = .{ .process = undefined, .options = &options, .endpoint = "/forward.sock" };
    try prepared.prepareChild(.{ .cwd = "/home/remote-user", .shell = "/bin/remote-shell" });

    try std.testing.expectEqualStrings("/home/remote-user", prepared.cwd_buffer[0..prepared.cwd_len]);
    try std.testing.expectEqual(@as(usize, 2), prepared.argument_count);
    try std.testing.expectEqualStrings("/bin/bash", prepared.argument_storage[0]);
    try std.testing.expectEqualStrings("-l", prepared.argument_storage[1]);
}

test "local Ghostty clients may use host shared memory" {
    var environment = try TestEnvironment.init(&.{.{ .name = "TERM_PROGRAM", .value = "Ghostty" }});
    defer environment.deinit();

    try std.testing.expect(supportsHostSharedMemory(.{ .block = environment.block }));
}

test "SSH clients never use host shared memory" {
    var environment = try TestEnvironment.init(&.{
        .{ .name = "TERM_PROGRAM", .value = "ghostty" },
        .{ .name = "SSH_CONNECTION", .value = "host 22 host 22" },
    });
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
}

test "other terminals do not use Ghostty shared memory" {
    var environment = try TestEnvironment.init(&.{.{ .name = "TERM_PROGRAM", .value = "iTerm.app" }});
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
    try std.testing.expect(!supportsHostSharedMemory(.empty));
}

test "the client snapshots EDITOR without inventing a fallback" {
    var environment = try TestEnvironment.init(&.{.{ .name = "EDITOR", .value = "/usr/bin/nvim" }});
    defer environment.deinit();

    try std.testing.expectEqualStrings(
        "/usr/bin/nvim",
        configuredEditor(.{ .block = environment.block }),
    );
    try std.testing.expectEqualStrings("", configuredEditor(.empty));
}
