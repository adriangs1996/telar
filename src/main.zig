const std = @import("std");
const build_options = @import("build_options");
const RecorderType = @import("telar-core").Recorder;
const max_args_module = @import("telar-backend").max_args;
const parser = @import("cli/parser.zig");
const usage_module = @import("cli/usage.zig");
const server_module = @import("cli/server.zig");
const history_module = @import("cli/history.zig");
const notification_module = @import("cli/notification.zig");
const config_module = @import("cli/config.zig");
const plugin_module = @import("cli/plugin.zig");
const run_module = @import("telar-backend").run;
const agent_module = @import("cli/agent.zig");
const pane_module = @import("cli/pane.zig");
const workspace_module = @import("cli/workspace.zig");
const api_module = @import("cli/api.zig");
const hook_module = @import("cli/hook.zig");
const integration_support = @import("cli/integration_support.zig");
const proxy_module = @import("cli/proxy.zig");
const skill_module = @import("cli/skill.zig");
const client_module = @import("cli/client.zig");

const version = "0.0.0";

test "the executable preserves diagnostic and trace root contracts" {
    try std.testing.expectEqual(build_options.diagnostics, telar_diagnostics);
    try std.testing.expectEqual(build_options.echo_trace, telar_echo_trace);
    try std.testing.expectEqual(build_options.echo_trace_cpu, telar_echo_trace_cpu);
    try std.testing.expectEqual(@import("builtin").mode == .Debug or telar_diagnostics, @import("telar-core").enabled);
}

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

// These names are root-level opt-in contracts read by core through @hasDecl.
pub const telar_diagnostics = build_options.diagnostics;
pub const telar_echo_trace = build_options.echo_trace;
pub const telar_echo_trace_cpu = build_options.echo_trace_cpu;

pub var echo_recorder: if (build_options.echo_trace) RecorderType else void = if (build_options.echo_trace) .{} else {};

fn dumpEchoTrace(init: std.process.Init) void {
    if (comptime build_options.echo_trace) {
        const directory = init.minimal.environ.getPosix("TELAR_ECHO_TRACE_DIR") orelse return;
        echo_recorder.dump(init.io, directory) catch {};
    }
}

fn collectArgs(init: std.process.Init, storage: *[max_args_module][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) {
            return error.TooManyArguments;
        }

        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

/// Selects and runs exactly one Telar command from the process arguments.
///
/// ```sh
/// telar server
/// ```
pub fn main(init: std.process.Init) !void {
    defer dumpEchoTrace(init);
    var arg_storage: [max_args_module][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try parser.Cli.parse(args, init.minimal.environ)) {
        .help => try std.Io.File.stdout().writeStreamingAll(init.io, usage_module.text),
        .version => try std.Io.File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try server_module.run(init, options),
        .history => |options| try history_module.run(init, options),
        .notification => |options| try notification_module.run(init, options),
        .config_check => |options| try config_module.runCheck(init, options),
        .plugin_worker => |options| try plugin_module.runWorker(init, options),
        .tap_worker => |options| try run_module(init, std.mem.span(options.entry)),
        .plugin => |options| try plugin_module.run(init, options),
        .agent => |options| std.process.exit(try agent_module.run(init, options)),
        .pane => |options| std.process.exit(try pane_module.run(init, options)),
        .workspace => |options| std.process.exit(try workspace_module.run(init, options)),
        .api => |options| try api_module.run(init, options),
        .hook => |options| try hook_module.run(init, options),
        .integration => |options| std.process.exit(try integration_support.run(init, options)),
        .proxy => |options| std.process.exit(try proxy_module.run(init, options)),
        .skill => try skill_module.run(init),
        .run => |options| {
            const status = try client_module.run(init, options);
            dumpEchoTrace(init);
            std.process.exit(status);
        },
    }
}

test {
    _ = @import("cli/RuntimeConfigSelection.zig");
    _ = @import("cli/RuntimeConnector.zig");
    _ = @import("cli/agent.zig");
    _ = @import("cli/api.zig");
    _ = @import("cli/arguments/AgentOptions.zig");
    _ = @import("cli/arguments/ApiOptions.zig");
    _ = @import("cli/arguments/ConfigCheckOptions.zig");
    _ = @import("cli/arguments/HistoryOptions.zig");
    _ = @import("cli/arguments/HookOptions.zig");
    _ = @import("cli/arguments/IntegrationOptions.zig");
    _ = @import("cli/arguments/NotificationOptions.zig");
    _ = @import("cli/arguments/PaneOptions.zig");
    _ = @import("cli/arguments/PluginOptions.zig");
    _ = @import("cli/arguments/PluginWorkerOptions.zig");
    _ = @import("cli/arguments/ProxyOptions.zig");
    _ = @import("cli/arguments/RunOptions.zig");
    _ = @import("cli/arguments/ServerOptions.zig");
    _ = @import("cli/arguments/TapWorkerOptions.zig");
    _ = @import("cli/arguments/WorkspaceOptions.zig");
    _ = @import("cli/arguments/agent.zig");
    _ = @import("cli/arguments/cursor_support.zig");
    _ = @import("cli/arguments/history.zig");
    _ = @import("cli/arguments/pane.zig");
    _ = @import("cli/arguments/plugin.zig");
    _ = @import("cli/arguments/server.zig");
    _ = @import("cli/arguments/values.zig");
    _ = @import("cli/client.zig");
    _ = @import("cli/config.zig");
    _ = @import("cli/control.zig");
    _ = @import("cli/history.zig");
    _ = @import("cli/hook.zig");
    _ = @import("cli/integration_support.zig");
    _ = @import("cli/notification.zig");
    _ = @import("cli/pane.zig");
    _ = @import("cli/parser.zig");
    _ = @import("cli/plugin.zig");
    _ = @import("cli/proxy.zig");
    _ = @import("cli/remote.zig");
    _ = @import("cli/runtime_connection.zig");
    _ = @import("cli/server.zig");
    _ = @import("cli/skill.zig");
    _ = @import("cli/usage.zig");
    _ = @import("cli/workspace.zig");
}
