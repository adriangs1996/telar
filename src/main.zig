const pty = @import("pty");
const core = @import("telar-core");
const backend = @import("telar-backend");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const slabheap = @import("slabheap");
const sqlite = @import("sqlite");
const parser = @import("cli/parser.zig");
const usage_module = @import("cli/usage.zig");
const server_module = @import("cli/server.zig");
const diagnostics_module = @import("cli/diagnostics.zig");
const runtime_module = @import("cli/runtime.zig");
const routed_module = @import("cli/routed.zig");
const client_control_module = @import("cli/client_control.zig");
const suggestion_module = @import("cli/suggestion.zig");
const tab_module = @import("cli/tab.zig");
const history_module = @import("cli/history.zig");
const notification_module = @import("cli/notification.zig");
const config_module = @import("cli/config.zig");
const plugin_module = @import("cli/plugin.zig");
const agent_module = @import("cli/agent.zig");
const pane_module = @import("cli/pane.zig");
const workspace_module = @import("cli/workspace.zig");
const worktree_module = @import("cli/worktree.zig");
const api_module = @import("cli/api.zig");
const hook_module = @import("cli/hook.zig");
const review_module = @import("cli/review.zig");
const integration_support = @import("cli/integration_support.zig");
const proxy_module = @import("cli/proxy.zig");
const skill_module = @import("cli/skill.zig");
const client_module = @import("cli/client.zig");
const RunOptions = @import("cli/arguments/RunOptions.zig");
const login_shell_module = @import("cli/login_shell.zig");
const cli_install_module = @import("cli/cli_install.zig");
const machine_profiles_module = @import("cli/machine_profiles.zig");
const machine_dispatch_module = @import("cli/machine_dispatch.zig");
const MachineDispatchOptions = @import("cli/arguments/MachineDispatchOptions.zig");

/// Exit status of a `--machine` command that never reached its machine.
const machine_dispatch_failure: u8 = 1;

const version = build_options.version;

// Zig tests use the compiler runner as root, not this bootstrap. Check the
// declarations here; executable probes exercise their root-level effects.
test "the executable preserves diagnostic and trace root contracts" {
    inline for (.{ "std_options", "telar_diagnostics", "telar_echo_trace", "telar_echo_trace_cpu", "echo_recorder", "telar_profile_counts", "telar_profile_timing", "profile_store" }) |name| {
        _ = std.meta.declarationInfo(@This(), name);
    }

    try std.testing.expectEqual(build_options.profile_counts, telar_profile_counts);
    try std.testing.expectEqual(build_options.profile_timing, telar_profile_timing);
    try std.testing.expectEqual(build_options.diagnostics, telar_diagnostics);
    try std.testing.expectEqual(build_options.echo_trace, telar_echo_trace);
    try std.testing.expectEqual(build_options.echo_trace_cpu, telar_echo_trace_cpu);
}

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
// GUI reload diagnostics have no terminal frame to corrupt and remain visible.
pub const std_options: std.Options = .{
    .log_level = .err,
    .log_scope_levels = &.{.{ .scope = .gui_config, .level = .warn }},
};

// These names are root-level opt-in contracts read by core through @hasDecl.
pub const telar_diagnostics = build_options.diagnostics;
pub const telar_profile_counts = build_options.profile_counts;
pub const telar_profile_timing = build_options.profile_timing;
pub var profile_store: if (core.profiling.active) core.ProfileStore else void = if (core.profiling.active) .{} else {};
pub const telar_echo_trace = build_options.echo_trace;
pub const telar_echo_trace_cpu = build_options.echo_trace_cpu;

pub var echo_recorder: if (build_options.echo_trace) core.Recorder else void = if (build_options.echo_trace) .{} else {};

fn dumpEchoTrace(init: std.process.Init) void {
    if (comptime core.profiling.active) {
        if (init.minimal.environ.getPosix("TELAR_PROFILE_DIR")) |directory| {
            profile_store.dump(init.io, directory) catch {};
        }
    }

    if (comptime build_options.echo_trace) {
        const directory = init.minimal.environ.getPosix("TELAR_ECHO_TRACE_DIR") orelse return;
        echo_recorder.dump(init.io, directory) catch {};
    }
}

fn collectArgs(init: std.process.Init, storage: *[pty.command_support.max_args][*:0]const u8) ![]const [*:0]const u8 {
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
pub const main = if (slab_heap_process) mainOnSlabHeap else runMain;

/// Zig 0.16 implements musl's `malloc` with `std.heap.SmpAllocator`, which
/// maps more memory after searching one other thread's free list, so what
/// the remaining threads freed stays unused and a runtime that allocates on
/// one thread and frees on another grows with every history batch. Release
/// builds for musl allocate from `slabheap` instead, for Zig and SQLite
/// alike. Debug builds keep the leak-checking allocator.
const slab_heap_process = builtin.target.abi.isMusl() and builtin.mode != .Debug;

// The process setup `std.start` does for `main(std.process.Init)`, with the
// slab heap as the general allocator of the command, its `Io` and SQLite.
fn mainOnSlabHeap(minimal: std.process.Init.Minimal) !void {
    const gpa = slabheap.allocator;
    try sqlite.routeMemory(gpa);

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();

    var environ_map = try std.process.Environ.createMap(minimal.environ, gpa);
    defer environ_map.deinit();

    const preopens = try std.process.Preopens.init(arena.allocator());
    try runMain(.{
        .minimal = minimal,
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    });
}

fn runMain(init: std.process.Init) !void {
    defer dumpEchoTrace(init);
    var arg_storage: [pty.command_support.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    try dispatch(init, args);
}

// Runs one parsed command. `--machine` and `dispatch-argv` come back here
// with the command they carry, so a command runs the same way wherever it
// arrives from.
fn dispatch(init: std.process.Init, args: []const [*:0]const u8) anyerror!void {
    switch (try parser.Cli.parse(args, init.minimal.environ)) {
        .help => try std.Io.File.stdout().writeStreamingAll(init.io, usage_module.text),
        .version => try std.Io.File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try server_module.run(init, options),
        .diagnostics => |options| std.process.exit(diagnostics_module.run(init, options)),
        .runtime => |options| std.process.exit(runtime_module.run(init, options)),
        .routed => |options| std.process.exit(routed_module.run(init, options)),
        .client_control => |options| std.process.exit(client_control_module.run(init, options)),
        .command => |options| std.process.exit(suggestion_module.run(init, options)),
        .tab => |options| std.process.exit(tab_module.run(init, options)),
        .history => |options| try history_module.run(init, options),
        .notification => |options| try notification_module.run(init, options),
        .config_check => |options| try config_module.runCheck(init, options),
        .plugin_worker => |options| try plugin_module.runWorker(init, options),
        .tap_worker => |options| try backend.run(init, std.mem.span(options.entry)),
        .plugin => |options| try plugin_module.run(init, options),
        .agent => |options| std.process.exit(try agent_module.run(init, options)),
        .pane => |options| std.process.exit(try pane_module.run(init, options)),
        .workspace => |options| std.process.exit(try workspace_module.run(init, options)),
        .worktree => |options| std.process.exit(try worktree_module.run(init, options)),
        .api => |options| try api_module.run(init, options),
        .hook => |options| try hook_module.run(init, options),
        .review => |options| std.process.exit(try review_module.run(init, options)),
        .integration => |options| std.process.exit(try integration_support.run(init, options)),
        .proxy => |options| std.process.exit(try proxy_module.run(init, options)),
        .skill => |which| try skill_module.run(init, which),
        .run => |options| {
            const status = try client_module.runNative(init, options);
            dumpEchoTrace(init);
            std.process.exit(status);
        },
        .gui => |options| {
            if (options.login_shell) {
                try login_shell_module.relaunch(init, args[2..]);
            }

            const status = try client_module.runNative(init, options.run);
            dumpEchoTrace(init);
            std.process.exit(status);
        },
        .cli => |options| try cli_install_module.run(init, options),
        .machine => |options| std.process.exit(try machine_profiles_module.run(init, options)),
        .machine_dispatch => |options| try dispatchToMachine(init, options),
        .dispatch_argv => |words| {
            const argv = try machine_dispatch_module.decode(init.gpa, words);
            defer machine_dispatch_module.freeDecoded(init.gpa, argv);

            try dispatch(init, argv);
        },
    }
}

fn openWindowOn(init: std.process.Init, label: [:0]const u8, run: RunOptions) anyerror!void {
    if (run.remote != null or run.machine != null) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "telar --machine: a window shows one machine first; drop --remote and the second --machine\n");
        std.process.exit(machine_dispatch_failure);
    }

    var options = run;
    options.machine = label.ptr;
    const status = try client_module.runNative(init, options);
    dumpEchoTrace(init);
    std.process.exit(status);
}

fn dispatchToMachine(init: std.process.Init, options: MachineDispatchOptions) anyerror!void {
    switch (try parser.Cli.parse(options.argv, init.minimal.environ)) {
        // Window options, or none: a window that shows the machine first.
        .run => |run| return openWindowOn(init, options.label, run),
        .gui => |gui| return openWindowOn(init, options.label, gui.run),
        .machine_dispatch, .dispatch_argv => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "telar --machine: runs one telar command there; it cannot name another machine\n");
            std.process.exit(machine_dispatch_failure);
        },
        else => {},
    }

    const target = machine_dispatch_module.resolve(init, options.label) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "telar --machine: {s}: {s}\n", .{
            options.label,
            if (err == error.UnknownMachine) "no saved machine or local label has that name; see `telar machine list`" else @errorName(err),
        }) catch "telar --machine: the machine cannot be resolved\n";
        try std.Io.File.stderr().writeStreamingAll(init.io, message);
        std.process.exit(machine_dispatch_failure);
    };

    switch (target) {
        .local => try dispatch(init, options.argv),
        .remote => |profile| std.process.exit(try machine_dispatch_module.forward(init, &profile, options.argv)),
    }
}

test {
    _ = @import("cli/arguments/TabOptions.zig");
    _ = @import("cli/arguments/MachineOptions.zig");
    _ = @import("cli/arguments/MachineDispatchOptions.zig");
    _ = @import("cli/dispatch_argv.zig");
    _ = @import("cli/machine_profiles.zig");
    _ = @import("cli/machine_dispatch.zig");
    _ = @import("cli/arguments/WorktreeOptions.zig");
    _ = @import("cli/repository_identity.zig");
    _ = @import("cli/worktree_dispatch.zig");
    _ = @import("cli/worktree_git.zig");
    _ = @import("cli/runtime.zig");
    _ = @import("cli/DiagnosticLog.zig");
    _ = @import("cli/arguments/DiagnosticsOptions.zig");
    _ = @import("cli/arguments/RuntimeOptions.zig");
    _ = @import("cli/agent.zig");
    _ = @import("cli/api.zig");
    _ = @import("cli/arguments/AgentOptions.zig");
    _ = @import("cli/arguments/ApiOptions.zig");
    _ = @import("cli/arguments/CliOptions.zig");
    _ = @import("cli/arguments/ConfigCheckOptions.zig");
    _ = @import("cli/arguments/GuiOptions.zig");
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
    _ = @import("cli/CodexSubagents.zig");
    _ = @import("cli/config.zig");
    _ = @import("cli/control.zig");
    _ = @import("cli/history.zig");
    _ = @import("cli/hook.zig");
    _ = @import("cli/hook_event.zig");
    _ = @import("cli/hook_progress.zig");
    _ = @import("cli/hook_worktree.zig");
    _ = @import("cli/WorktreeCatalog.zig");
    _ = @import("cli/integration_support.zig");
    _ = @import("cli/TempFile.zig");
    _ = @import("cli/login_shell.zig");
    _ = @import("cli/notification.zig");
    _ = @import("cli/pane.zig");
    _ = @import("cli/parser.zig");
    _ = @import("cli/plugin.zig");
    _ = @import("cli/proxy.zig");
    _ = @import("cli/server.zig");
    _ = @import("cli/skill.zig");
    _ = @import("cli/usage.zig");
    _ = @import("cli/workspace.zig");
}
