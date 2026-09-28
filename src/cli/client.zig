//! Composition of the interactive Telar client process.

const gui = @import("telar-gui");
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const RunOptions = @import("arguments/RunOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const ClientLaunch = @import("ClientLaunch.zig");
const TestEnvironment = @import("TestEnvironment.zig");

/// Opens the native window, which `telar` and `telar gui` both do. The
/// window opens first and connects to its machine by itself, so nothing
/// here waits on SSH or a runtime start.
///
/// ```zig
/// const exit_code = try client.runNative(process_init, options);
/// ```
pub fn runNative(init: std.process.Init, options: RunOptions) !u8 {
    if (comptime !build_options.native_client) {
        std.debug.print("{s}", .{no_window_build_message});
        return no_window_status;
    }

    if (!displayAvailable(init.minimal.environ)) {
        std.debug.print("{s}", .{no_display_message});
        return no_window_status;
    }

    // The window's identity lease lives in the local runtime directory,
    // which exists even before any runtime runs.
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, null);
    try connector.prepareServerDirectory();

    var prepared: ClientLaunch = undefined;
    try prepared.prepare(.{
        .process = init,
        .options = &options,
        .endpoint = connector.endpointPath(),
    });
    defer prepared.deinit();

    // The window's own client is this machine's; a `--remote` machine
    // opens beside it, runs the named command, and is shown first.
    var frontend_options = prepared.frontendOptions();
    frontend_options.machine = .{ .local = .{
        .path = options.config,
        .disabled = options.no_config,
        .profile = options.profile,
        .fresh = options.fresh,
    } };
    var profiles: core.MachineProfiles = .{};
    const opened = if (options.machine) |label|
        savedDestination(init, std.mem.span(label), &profiles) catch |err| {
            std.debug.print("telar gui: {s}\n", .{switch (err) {
                error.UnknownMachine => "no saved machine or local label has that name; see telar machine list",
                else => @errorName(err),
            }});
            return 1;
        }
    else if (options.remote) |destination|
        std.mem.span(destination)
    else
        null;
    if (opened) |destination| {
        frontend_options.open_machine = .{
            .destination = destination,
            .arguments = prepared.command(),
        };
        frontend_options.arguments = &.{defaultShell(init.minimal.environ)};
    }
    prepared.transferResources();
    return gui.run(init, null, frontend_options);
}

// The destination of the saved machine `label` names, or null when it is
// this machine's label. `profiles` holds the text the result points into.
fn savedDestination(init: std.process.Init, label: []const u8, profiles: *core.MachineProfiles) !?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try client.profile_file.path(init.minimal.environ, &path_buffer);
    profiles.* = try client.profile_file.load(init.io, init.gpa, path);

    if (profiles.find(label)) |index| {
        return profiles.rows[index].destination();
    }

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.mem.eql(u8, client.profile_file.localLabel(profiles, &hostname_buffer), label)) {
        return null;
    }

    return error.UnknownMachine;
}

fn defaultShell(environ: std.process.Environ) []const u8 {
    const shell = environ.getPosix("SHELL") orelse return "/bin/sh";
    return if (shell.len == 0) "/bin/sh" else shell;
}

/// Exit status when no window can open here.
const no_window_status: u8 = 1;

const cli_hint =
    \\From a terminal, reach the panes and agents through the CLI:
    \\  telar pane read|watch|send-keys, telar agent prompt, telar --machine LABEL COMMAND
    \\
;

const no_display_message =
    \\telar: no display to open a window here (an SSH login, or Linux without WAYLAND_DISPLAY).
    \\
++ cli_hint;

// A headless release leaves the window out on purpose: it ships the
// runtime and the CLI.
const no_window_build_message =
    \\telar: this build has no window; it ships the runtime and the CLI.
    \\
++ cli_hint;

// A window needs a display: Wayland on Linux (X11 is not supported), and
// on macOS a login session rather than an SSH one, whose window server
// AppKit would fail to reach.
fn displayAvailable(environ: std.process.Environ) bool {
    return switch (builtin.os.tag) {
        .linux => if (environ.getPosix("WAYLAND_DISPLAY")) |display| display.len != 0 else false,
        .macos => environ.getPosix("SSH_CONNECTION") == null and environ.getPosix("SSH_TTY") == null,
        else => false,
    };
}

pub fn configuredEditor(environ: std.process.Environ) []const u8 {
    return environ.getPosix("EDITOR") orelse "";
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
