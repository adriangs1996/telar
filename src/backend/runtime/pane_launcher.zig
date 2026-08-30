//! Cohesive pane launch transaction.
//!
//! Allocation, proxy registration, process creation, store insertion, and
//! actor scheduling either establish a fully observable pane or execute the
//! matching rollback path.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../history/root.zig");
const pane_mod = @import("../pane/root.zig");
const pane_exit_coordinator = @import("pane_exit_coordinator.zig");
const pane_output_pipeline = @import("pane_output_pipeline.zig");
const proxy_mod = @import("../proxy/root.zig");
const pty = @import("../pty/root.zig");

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
        child_environment: *const pty.Environment,
        inherited_environment: std.process.Environ,
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
            var proxy_environment: ?proxy_mod.PaneEnvironment = null;
            defer if (proxy_environment) |*owned| owned.deinit();
            var proxy_registered = false;
            errdefer if (proxy_registered) if (launcher.proxy) |proxy|
                proxy.revokePane(pane_key);
            const child_environment = if (launcher.proxy) |proxy| block: {
                proxy_environment = try proxy.registerPane(
                    pane_key,
                    launcher.inherited_environment,
                );
                proxy_registered = true;
                break :block proxy_environment.?.environment();
            } else launcher.child_environment;

            var command = try OwnedCommand.init(
                launcher.gpa,
                request.launch,
                request.launch_cwd,
                child_environment,
            );
            defer command.deinit();
            const shell = std.mem.span(command.command.file);
            const fresh = try Pane.create(
                launcher.io,
                launcher.gpa,
                pane_key,
                request.location,
                &command.command,
                request.launch_cwd,
                request.workspace_path,
                launcher.history_service,
                request.size,
                launcher.panes.graphics_limits,
                &launcher.panes.graphics_budget,
            );

            launcher.panes.insert(fresh) catch |err| {
                launcher.recordFailure(fresh, shell, .pane_registration, err);
                fresh.abortLaunch();
                fresh.destroy();
                return err;
            };
            launcher.injectFault(.pane_registration) catch |err| {
                launcher.abort(fresh, shell, .pane_registration, err);
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            // The wait actor owns reaping if output actor scheduling fails.
            const wait_started = fresh.beginExitWait();
            std.debug.assert(wait_started);
            launcher.injectFault(.wait_actor) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, shell, .wait_actor, err);
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };
            launcher.select.concurrent(.pane_exit, waitPane, .{fresh}) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, shell, .wait_actor, err);
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            const output_started = fresh.beginPtyOutputRead();
            std.debug.assert(output_started);
            launcher.injectFault(.output_actor) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, shell, .output_actor, err);
                return err;
            };
            launcher.select.concurrent(.pane_output, readPane, .{ launcher.io, fresh }) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, shell, .output_actor, err);
                return err;
            };

            fresh.commitLaunch(shell);
            proxy_registered = false;
            return fresh;
        }

        fn injectFault(launcher: *Self, phase: history.LaunchPhase) !void {
            if (launcher.launch_fault) |fault| try fault.inject(phase);
        }

        fn recordFailure(
            launcher: *Self,
            pane: *const Pane,
            shell: []const u8,
            phase: history.LaunchPhase,
            cause: anyerror,
        ) void {
            _ = launcher.history_service.recordLaunchAttempt(
                launcher.io,
                pane.id,
                pane.generation,
                pane.location,
                pane.workspace_path,
                shell,
                pane.started_at_ms,
                phase,
                @errorName(cause),
            );
        }

        fn abort(
            launcher: *Self,
            pane: *Pane,
            shell: []const u8,
            phase: history.LaunchPhase,
            cause: anyerror,
        ) void {
            launcher.recordFailure(pane, shell, phase, cause);
            pane.abortLaunch();
        }
    };
}

const OwnedCommand = struct {
    command: pty.Command,
    arguments: []const [:0]u8,
    cwd: [:0]u8,
    gpa: std.mem.Allocator,

    fn init(
        gpa: std.mem.Allocator,
        launch: schema.LaunchView,
        cwd_path: []const u8,
        environment: *const pty.Environment,
    ) !OwnedCommand {
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
    const len = pane.session.file().readStreaming(io, &.{&pane.output_buffer}) catch |err|
        return .{ .pane = pane.key(), .result = err };
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

fn waitPane(pane: *Pane) PaneExitEvent {
    return .{ .pane = pane.key(), .result = pane.session.wait() };
}
