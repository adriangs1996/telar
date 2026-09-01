//! Cohesive pane launch transaction.
//!
//! Allocation, proxy registration, process creation, store insertion, and
//! actor scheduling either establish a fully observable pane or execute the
//! matching rollback path.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const pane_exit_coordinator = @import("../entrypoints/events/pane/exit.zig");
const pane_output_pipeline = @import("../entrypoints/events/pane/output.zig");
const proxy_mod = @import("../../proxy/root.zig");
const pty = @import("../../pty/root.zig");

const Io = std.Io;
const Pane = pane_mod.Pane;
const PaneStore = pane_mod.PaneStore;
const schema = core.schema;

comptime {
    std.debug.assert(schema.max_argument_count <= pty.max_args);
}

pub const PaneOutputEvent = pane_output_pipeline.Completion;

pub const PaneExitEvent = pane_exit_coordinator.Completion;

pub const LaunchRequest = struct {
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    launch_cwd: []const u8,
    workspace_path: []const u8,
};

pub const PaneIdentity = struct {
    key: pane_mod.PaneKey,
    location: schema.TabLocation,
    socket_path: []const u8,
};

/// Fixed storage for the environment variables that let a child find the
/// runtime and name its own pane. `TELAR_SOCKET` stays absent on purpose: a
/// nested runtime must not inherit the outer listener as its own.
pub const PaneOverrides = struct {
    pub const count = 5;

    pane_id: [20]u8 = undefined,
    pane_generation: [20]u8 = undefined,
    workspace_id: [20]u8 = undefined,
    tab_id: [20]u8 = undefined,
    entries: [count]pty.ChildEnvironment.Override = undefined,

    /// Formats the identity into owned decimal storage and returns the
    /// override slice borrowed from `overrides`.
    ///
    /// ```zig
    /// var overrides: PaneOverrides = .{};
    /// const entries = overrides.build(.{ .key = key, .location = location, .socket_path = path });
    /// ```
    pub fn build(overrides: *PaneOverrides, identity: PaneIdentity) []const pty.ChildEnvironment.Override {
        const pane_id = std.fmt.bufPrint(&overrides.pane_id, "{d}", .{schema.id.raw(identity.key.id)}) catch unreachable;
        const pane_generation = std.fmt.bufPrint(&overrides.pane_generation, "{d}", .{identity.key.generation}) catch unreachable;
        const workspace_id = std.fmt.bufPrint(&overrides.workspace_id, "{d}", .{schema.id.raw(identity.location.workspace.workspace)}) catch unreachable;
        const tab_id = std.fmt.bufPrint(&overrides.tab_id, "{d}", .{schema.id.raw(identity.location.tab_id)}) catch unreachable;
        overrides.entries = .{
            .{ .name = "TELAR_SOCKET_PATH", .value = identity.socket_path },
            .{ .name = "TELAR_PANE_ID", .value = pane_id },
            .{ .name = "TELAR_PANE_GENERATION", .value = pane_generation },
            .{ .name = "TELAR_WORKSPACE_ID", .value = workspace_id },
            .{ .name = "TELAR_TAB_ID", .value = tab_id },
        };
        return &overrides.entries;
    }
};

comptime {
    std.debug.assert(PaneOverrides.count <= proxy_mod.max_pane_overrides);
}

const LaunchFailure = struct {
    shell: []const u8,
    phase: history.LaunchPhase,
    cause: anyerror,
};

const CommandInitialization = struct {
    gpa: std.mem.Allocator,
    launch: schema.LaunchView,
    cwd_path: []const u8,
    environment: *const pty.ChildEnvironment,
};

/// One-shot integration seam for post-spawn launch recovery.
pub const LaunchTestFault = struct {
    phase: history.LaunchPhase,
    claimed: std.atomic.Value(bool) = .init(false),

    pub fn inject(fault: *LaunchTestFault, phase: history.LaunchPhase) !void {
        if (fault.phase != phase) return;
        if (fault.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        return error.InjectedLaunchFailure;
    }
};

pub fn PaneLauncher(comptime RuntimeEvent: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: std.mem.Allocator,
        select: *Io.Select(RuntimeEvent),
        history_service: *history.Service,
        inherited_environment: std.process.Environ,
        socket_path: []const u8,
        manifests: *const core.agent_manifest.Table,
        proxy: ?*proxy_mod.Proxy,
        panes: *PaneStore,
        launch_fault: ?*LaunchTestFault,

        /// Executes one pane-launch transaction and returns only after both
        /// runtime observation actors own their work.
        ///
        /// ```zig
        /// const pane = try launcher.launch(.{ .location = location, .size = size, .launch = view, .launch_cwd = cwd, .workspace_path = path });
        /// ```
        pub fn launch(launcher: *Self, request: LaunchRequest) !*Pane {
            const pane_key = try launcher.panes.allocateKey();
            var pane_overrides: PaneOverrides = .{};
            const identity_overrides = pane_overrides.build(.{
                .key = pane_key,
                .location = request.location,
                .socket_path = launcher.socket_path,
            });
            var proxy_environment: ?proxy_mod.PaneEnvironment = null;
            defer if (proxy_environment) |*owned| owned.deinit();
            var owned_environment: ?pty.ChildEnvironment = null;
            defer if (owned_environment) |*owned| owned.deinit();
            var proxy_registered = false;
            errdefer if (proxy_registered) if (launcher.proxy) |proxy|
                proxy.revokePane(pane_key);
            const child_environment = if (launcher.proxy) |proxy| block: {
                proxy_environment = try proxy.registerPane(
                    pane_key,
                    launcher.inherited_environment,
                    identity_overrides,
                );
                proxy_registered = true;
                break :block proxy_environment.?.environment();
            } else block: {
                owned_environment = try pty.ChildEnvironment.initWithOverrides(
                    launcher.gpa,
                    launcher.inherited_environment,
                    .{ .telar_term_program = "telar", .overrides = identity_overrides },
                );
                break :block &owned_environment.?;
            };

            var command = try OwnedCommand.init(.{
                .gpa = launcher.gpa,
                .launch = request.launch,
                .cwd_path = request.launch_cwd,
                .environment = child_environment,
            });
            defer command.deinit();
            const shell = std.mem.span(command.command.file);
            const fresh = try Pane.create(.{
                .io = launcher.io,
                .gpa = launcher.gpa,
                .history_service = launcher.history_service,
                .graphics_budget = &launcher.panes.graphics_budget,
                .manifests = launcher.manifests,
            }, .{
                .identity = pane_key,
                .location = request.location,
                .command = &command.command,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
                .size = request.size,
                .graphics_limits = launcher.panes.graphics_limits,
            });

            fresh.launch_record.capture(request.launch);
            launcher.panes.insert(fresh) catch |err| {
                launcher.recordFailure(fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
                fresh.abortLaunch();
                fresh.destroy();
                return err;
            };
            launcher.injectFault(.pane_registration) catch |err| {
                launcher.abort(fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            // The wait actor owns reaping if output actor scheduling fails.
            const wait_started = fresh.beginExitWait();
            std.debug.assert(wait_started);
            launcher.injectFault(.wait_actor) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };
            launcher.select.concurrent(.pane_exit, waitPane, .{fresh}) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            const output_started = fresh.beginPtyOutputRead();
            std.debug.assert(output_started);
            launcher.injectFault(.output_actor) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
                return err;
            };
            launcher.select.concurrent(.pane_output, readPane, .{ launcher.io, fresh }) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
                return err;
            };

            fresh.commitLaunch(shell);
            proxy_registered = false;
            return fresh;
        }

        fn injectFault(launcher: *Self, phase: history.LaunchPhase) !void {
            if (launcher.launch_fault) |fault| try fault.inject(phase);
        }

        fn recordFailure(launcher: *Self, pane: *const Pane, failure: LaunchFailure) void {
            _ = launcher.history_service.recordLaunchAttempt(launcher.io, .{
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .location = pane.location,
                .workspace_path = pane.workspace_path,
                .shell = failure.shell,
                .started_at_ms = pane.started_at_ms,
                .phase = failure.phase,
                .cause = @errorName(failure.cause),
            });
        }

        fn abort(launcher: *Self, pane: *Pane, failure: LaunchFailure) void {
            launcher.recordFailure(pane, failure);
            pane.abortLaunch();
        }
    };
}

const OwnedCommand = struct {
    command: pty.Command,
    arguments: []const [:0]u8,
    cwd: [:0]u8,
    gpa: std.mem.Allocator,

    fn init(initialization: CommandInitialization) !OwnedCommand {
        const gpa = initialization.gpa;
        const launch = initialization.launch;
        const cwd_path = initialization.cwd_path;
        const environment = initialization.environment;

        if (launch.environment_mode != .inherit_runtime or launch.environment_count != 0)
            return error.UnsupportedEnvironment;

        const arguments = try gpa.alloc([:0]u8, launch.argument_count);
        errdefer gpa.free(arguments);
        var initialized: usize = 0;
        errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);

        var iterator = launch.arguments();
        while (try iterator.next()) |argument| {
            arguments[initialized] = try gpa.dupeZ(u8, argument);
            initialized += 1;
        }
        const cwd = try gpa.dupeZ(u8, cwd_path);
        errdefer gpa.free(cwd);

        var command: pty.Command = .{
            .file = arguments[0].ptr,
            .cwd = cwd.ptr,
            .environment = environment,
        };
        for (arguments, 0..) |argument, index| command.argv[index] = argument.ptr;
        return .{ .command = command, .arguments = arguments, .cwd = cwd, .gpa = gpa };
    }

    fn deinit(command: *OwnedCommand) void {
        for (command.arguments) |argument| command.gpa.free(argument);
        command.gpa.free(command.arguments);
        command.gpa.free(command.cwd);
    }
};

pub fn readPane(io: Io, pane: *Pane) PaneOutputEvent {
    const len = pane.session.read(io, &pane.output_buffer) catch |err|
        return .{ .pane = pane.key(), .result = err };
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

fn waitPane(pane: *Pane) PaneExitEvent {
    return .{ .pane = pane.key(), .result = pane.session.wait() };
}

test "pane overrides name the runtime socket and the pane's own identity" {
    var overrides: PaneOverrides = .{};

    const entries = overrides.build(.{
        .key = .{ .id = try schema.id.pane(12), .generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(4) },
            .tab_id = @enumFromInt(9),
        },
        .socket_path = "/tmp/telar.sock",
    });

    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("TELAR_SOCKET_PATH", entries[0].name);
    try std.testing.expectEqualStrings("/tmp/telar.sock", entries[0].value);
    try std.testing.expectEqualStrings("TELAR_PANE_ID", entries[1].name);
    try std.testing.expectEqualStrings("12", entries[1].value);
    try std.testing.expectEqualStrings("TELAR_PANE_GENERATION", entries[2].name);
    try std.testing.expectEqualStrings("3", entries[2].value);
    try std.testing.expectEqualStrings("TELAR_WORKSPACE_ID", entries[3].name);
    try std.testing.expectEqualStrings("4", entries[3].value);
    try std.testing.expectEqualStrings("TELAR_TAB_ID", entries[4].name);
    try std.testing.expectEqualStrings("9", entries[4].value);
}
