const repository_prepare = @import("cli/repository_prepare.zig");
const file_transfer = @import("cli/file_transfer.zig");
const project_setup = @import("cli/project_setup.zig");
const execution = @import("cli/execution.zig");
const core = @import("telar-core");
const backend = @import("telar-backend");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const slabheap = @import("slabheap");
const sqlite = @import("sqlite");
const parser = @import("cli/parser.zig");
const control = @import("cli/control.zig");
const cli_limit_reached = @import("cli/limit_reached.zig");
const help_module = @import("cli/help.zig");
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

// Library warnings cannot be written over a live frame; the bootstrap keeps
// stderr out of the drawing path. GUI reload diagnostics have no terminal
// frame to corrupt and remain visible, and so do reached limits: the
// daemonized runtime's stderr is its log file (`ServerLaunch.launchDaemon`).
pub const std_options: std.Options = .{
    .log_level = .err,
    .log_scope_levels = &.{
        .{
            .scope = .gui_config,
            .level = .warn,
        },
        .{
            .scope = .limits,
            .level = .warn,
        },
    },
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
            profile_store.dump(init.io, directory) catch |err| std.log.warn("Could not write profiling data: {s}", .{@errorName(err)});
        }
    }

    if (comptime build_options.echo_trace) {
        const directory = init.minimal.environ.getPosix("TELAR_ECHO_TRACE_DIR") orelse return;
        echo_recorder.dump(init.io, directory) catch |err| std.log.warn("Could not write echo trace: {s}", .{@errorName(err)});
    }
}

// The command line in the process arena, however long: each command
// bounds its own arguments and says so by name.
fn collectArgs(init: std.process.Init) ![]const [*:0]const u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const pointers = try arena.alloc([*:0]const u8, args.len);
    for (args, pointers) |arg, *pointer| {
        pointer.* = arg.ptr;
    }

    return pointers;
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
    const args = try collectArgs(init);

    try dispatch(init, args);
}

// Runs one parsed command. `--machine` and `dispatch-argv` come back here
// with the command they carry, so a command runs the same way wherever it
// arrives from.
fn dispatch(init: std.process.Init, args: []const [*:0]const u8) anyerror!void {
    switch (parseCommand(init, args)) {
        .repository => |options| std.process.exit(repository_prepare.run(init, options)),
        .file => |options| std.process.exit(file_transfer.run(init, options)),
        .project => |options| std.process.exit(project_setup.run(init, options)),
        .exec => |options| std.process.exit(execution.run(init, options)),
        .help => |topic| try help_module.run(init, topic),
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

// A command line telar cannot read ends the process with one line naming
// what is wrong, not with the parser's error return trace.
fn parseCommand(init: std.process.Init, args: []const [*:0]const u8) parser.Cli {
    return parser.Cli.parse(args, init.minimal.environ) catch |err| {
        if (err == error.TooManyArguments) {
            cli_limit_reached.report(.{
                .limit = control.command_arguments_limit,
                .requested = args.len,
            });
        }

        var topic_buffer: [64]u8 = undefined;
        // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
        std.debug.print("telar: {s}; see `telar {s}--help`\n", .{ control.describe(err), help_module.topic(args, &topic_buffer) });
        std.process.exit(agent_module.exit_failure);
    };
}

fn dispatchToMachine(init: std.process.Init, options: MachineDispatchOptions) anyerror!void {
    switch (parseCommand(init, options.argv)) {
        .help => |topic| return help_module.run(init, topic),
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
