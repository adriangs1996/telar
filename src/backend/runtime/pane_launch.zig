//! Pane launch transaction (ADR 0001).
//!
//! Allocation, environment preparation, process creation, table insertion
//! and actor scheduling either establish a fully observable pane or run the
//! matching rollback path.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const limit_reached = @import("limit_reached.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const pty = @import("pty");
const command_support = pty.command_support;
const proxy_mod = @import("../proxy/proxy_namespace.zig");
const history_model = @import("../history/model.zig");
const LaunchRequest = @import("LaunchRequest.zig");
const Override = pty.Override;
const PaneKey = @import("../pane/PaneKey.zig");
const OwnedCommand = @import("OwnedCommand.zig");
const Pane = @import("../pane/Pane.zig");
const PaneEnvironment = @import("../proxy/PaneEnvironment.zig");
const ChildEnvironment = pty.ChildEnvironment;
const OutputCompletion = @import("events/OutputCompletion.zig");
const ExitCompletion = @import("events/ExitCompletion.zig");
const terminal_colors = @import("terminal_colors.zig");

comptime {
    std.debug.assert(core.max_argument_count <= command_support.max_args);
    std.debug.assert(PaneOverrides.count <= proxy_mod.max_pane_overrides);
}

const Failure = struct {
    shell: []const u8,
    phase: history_model.LaunchPhase,
    cause: anyerror,
};

/// Starts a pane and returns only after the runtime owns both its output
/// and exit actors. Client attachment and response delivery happen later.
///
/// ```zig
/// const pane = try pane_launch.launch(model, .{ .location = location, .size = size, .launch = view, .launch_cwd = cwd, .workspace_path = path });
/// ```
pub fn launch(model: *RuntimeModel, request: LaunchRequest) !*Pane {
    const fresh = launchTerminal(model, request) catch |err| {
        reportLimit(model, request.location, err);
        return err;
    };

    session_checkpoint.noteChange(model);
    return fresh;
}

/// What a client reads when a launch names a program the runtime cannot find.
/// The runtime searches its own PATH, the environment it was started with.
pub const program_not_found = "could not start the command: the program does not exist or is not on the runtime's PATH";
pub const program_not_executable = "could not start the command: the program is not executable";
pub const directory_unusable = "could not start the command: its working directory does not exist or cannot be entered";
pub const spawn_failed = "could not start the command";

/// What a client reads when the runtime or the tab holds all the panes it can.
pub const pane_limit = std.fmt.comptimePrint("the runtime holds its limit of {d} panes; close a pane first", .{PaneStore.capacity});
pub const tab_pane_limit = std.fmt.comptimePrint("this tab holds its limit of {d} panes; open a new tab", .{core.max_panes_per_tab});

/// The reason a request that stopped at a pane limit fails with, or null
/// when `launch_error` is not a pane limit.
///
/// ```zig
/// error.PaneLimitReached, error.TabPaneLimitReached => client_request.fail(session, id, .resource_limit, pane_launch.limitFailure(err).?),
/// ```
pub fn limitFailure(launch_error: anyerror) ?[]const u8 {
    return switch (launch_error) {
        error.PaneLimitReached => pane_limit,
        error.TabPaneLimitReached => tab_pane_limit,
        else => null,
    };
}

/// Narrows a launch failure to the errors requests report to clients.
///
/// ```zig
/// const pane = pane_launch.launch(model, request) catch |err| return pane_launch.requestError(err);
/// ```
pub fn requestError(launch_error: anyerror) anyerror {
    return switch (launch_error) {
        error.PaneLimitReached,
        error.TabPaneLimitReached,
        error.UnsupportedEnvironment,
        error.ExecutableNotFound,
        error.ExecutableAccessDenied,
        error.InvalidExecutable,
        error.InvalidWorkingDirectory,
        => launch_error,
        else => error.PaneSpawnFailed,
    };
}

/// The reason a request whose child could not start fails with, or null
/// when `launch_error` is not about starting the child.
///
/// ```zig
/// else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, id, .spawn_failed, reason) else err,
/// ```
pub fn spawnFailure(launch_error: anyerror) ?[]const u8 {
    return switch (launch_error) {
        error.ExecutableNotFound => program_not_found,
        error.ExecutableAccessDenied, error.InvalidExecutable => program_not_executable,
        error.InvalidWorkingDirectory => directory_unusable,
        error.PaneSpawnFailed => spawn_failed,
        else => null,
    };
}

/// Output actor: one PTY read into the pane's output buffer.
/// Example: `try select.concurrent(.pane_output, pane_launch.readPane, .{ io, pane });`.
pub fn readPane(io: std.Io, pane: *Pane) OutputCompletion {
    const len = pane.session.read(io, &pane.output_buffer) catch |err|
        return .{ .pane = pane.key(), .result = err };
    core.mark(io, .pty_read);
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

/// Exit actor: waits for the child and reports its status.
/// Example: `try select.concurrent(.pane_exit, pane_launch.waitPane, .{pane});`.
pub fn waitPane(pane: *Pane) ExitCompletion {
    return .{ .pane = pane.key(), .result = pane.session.wait() };
}

fn reportLimit(model: *RuntimeModel, location: core.TabLocation, launch_error: anyerror) void {
    switch (launch_error) {
        error.PaneLimitReached => limit_reached.report(model, .{
            .limit = PaneStore.panes_limit,
            .requested = model.panes.count + 1,
        }),
        error.TabPaneLimitReached => limit_reached.report(model, .{
            .limit = PaneStore.tab_panes_limit,
            .requested = model.panes.occupancyAt(location) + 1,
        }),
        else => {},
    }
}

fn launchTerminal(model: *RuntimeModel, request: LaunchRequest) !*Pane {
    const proxy = model.resources.proxy.capability();
    const pane_key = try model.panes.allocateKey(request.location);
    var pane_overrides: PaneOverrides = .{};
    const identity_overrides = pane_overrides.build(pane_key, request.location, model.socket_path, model.executable_path[0..model.executable_path_len]);
    var proxy_environment: ?PaneEnvironment = null;
    defer if (proxy_environment) |*owned| owned.deinit();
    var owned_environment: ?ChildEnvironment = null;
    defer if (owned_environment) |*owned| owned.deinit();

    const child_environment = if (proxy) |active| block: {
        proxy_environment = try active.environment(.{
            .inherited = model.inherited_environment,
            .overrides = identity_overrides,
        });
        break :block proxy_environment.?.environment();
    } else block: {
        owned_environment = try ChildEnvironment.initWithOverrides(
            model.gpa,
            model.inherited_environment,
            .{ .telar_term_program = "telar", .overrides = identity_overrides },
        );
        break :block &owned_environment.?;
    };

    var command = try OwnedCommand.init(model.gpa, request.launch, request.launch_cwd, child_environment);
    defer command.deinit();

    const shell = std.mem.span(command.command.file);
    const fresh = try Pane.create(.{
        .io = model.io,
        .gpa = model.gpa,
        .history_service = model.resources.history.service(),
        .graphics_budget = &model.panes.graphics_budget,
        .manifests = &model.resources.agent_manifests,
    }, .{
        .identity = pane_key,
        .location = request.location,
        .command = &command.command,
        .launch_cwd = request.launch_cwd,
        .workspace_path = request.workspace_path,
        .size = request.size,
        .graphics_limits = model.panes.graphics_limits,
        .terminal_colors = terminal_colors.ofWorkspace(model, request.location.workspace),
    });

    fresh.launch_record.capture(model.gpa, request.launch) catch |err| {
        recordFailure(model, fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
        fresh.abortLaunch();
        fresh.destroy();
        return err;
    };
    model.panes.insert(fresh) catch |err| {
        recordFailure(model, fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
        fresh.abortLaunch();
        fresh.destroy();
        return err;
    };
    injectFault(model, .pane_registration) catch |err| {
        abort(model, fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
        model.panes.removeAndDestroy(fresh);
        return err;
    };

    // The wait actor owns reaping if output actor scheduling fails.
    const wait_started = fresh.beginExitWait();
    std.debug.assert(wait_started);
    injectFault(model, .wait_actor) catch |err| {
        fresh.cancelExitWait();
        abort(model, fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
        model.panes.removeAndDestroy(fresh);
        return err;
    };
    model.select.concurrent(.pane_exit, waitPane, .{fresh}) catch |err| {
        fresh.cancelExitWait();
        abort(model, fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
        model.panes.removeAndDestroy(fresh);
        return err;
    };

    const output_started = fresh.beginPtyOutputRead();
    std.debug.assert(output_started);
    injectFault(model, .output_actor) catch |err| {
        fresh.cancelPtyOutputRead();
        fresh.finishPtyOutput();
        abort(model, fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
        return err;
    };
    model.select.concurrent(.pane_output, readPane, .{ model.io, fresh }) catch |err| {
        fresh.cancelPtyOutputRead();
        fresh.finishPtyOutput();
        abort(model, fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
        return err;
    };

    fresh.commitLaunch(shell);
    return fresh;
}

fn injectFault(model: *RuntimeModel, phase: history_model.LaunchPhase) !void {
    if (model.launch_fault) |fault| {
        try fault.inject(phase);
    }
}

fn recordFailure(model: *RuntimeModel, pane: *const Pane, failure: Failure) void {
    _ = model.resources.history.service().recordLaunchAttempt(model.io, .{
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

fn abort(model: *RuntimeModel, pane: *Pane, failure: Failure) void {
    recordFailure(model, pane, failure);
    pane.abortLaunch();
    model.review_owner_revision +%= 1;
}

test "pane overrides name the runtime socket and the pane's own identity" {
    var overrides: PaneOverrides = .{};

    const entries = overrides.build(
        .{ .id = try core.pane(12), .generation = 3 },
        .{ .workspace = .{ .workspace = @enumFromInt(4) }, .tab_id = @enumFromInt(9) },
        "/tmp/telar.sock",
        "/opt/telar/bin/telar",
    );

    try std.testing.expectEqual(@as(usize, 6), entries.len);
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
    try std.testing.expectEqualStrings("TELAR_BIN_PATH", entries[5].name);
    try std.testing.expectEqualStrings("/opt/telar/bin/telar", entries[5].value);
}

const PaneOverrides = struct {
    /// Fixed storage for the environment variables that let a child find the
    /// runtime and name its own pane. `TELAR_SOCKET` stays absent on purpose: a
    /// nested runtime must not inherit the outer listener as its own.
    pub const count = 6;

    pane_id: [20]u8 = undefined,
    pane_generation: [20]u8 = undefined,
    workspace_id: [20]u8 = undefined,
    tab_id: [20]u8 = undefined,
    entries: [count]Override = undefined,

    /// Formats the identity into owned decimal storage and returns the
    /// override slice borrowed from `overrides`.
    ///
    /// ```zig
    /// var overrides: PaneOverrides = .{};
    /// const entries = overrides.build(key, location, socket_path, executable_path);
    /// ```
    pub fn build(self: *PaneOverrides, key: PaneKey, location: core.TabLocation, socket_path: []const u8, executable_path: []const u8) []const Override {
        const pane_id = std.fmt.bufPrint(&self.pane_id, "{d}", .{core.raw(key.id)}) catch unreachable;
        const pane_generation = std.fmt.bufPrint(&self.pane_generation, "{d}", .{key.generation}) catch unreachable;
        const workspace_id = std.fmt.bufPrint(&self.workspace_id, "{d}", .{core.raw(location.workspace.workspace)}) catch unreachable;
        const tab_id = std.fmt.bufPrint(&self.tab_id, "{d}", .{core.raw(location.tab_id)}) catch unreachable;
        self.entries = .{
            .{ .name = "TELAR_SOCKET_PATH", .value = socket_path },
            .{ .name = "TELAR_PANE_ID", .value = pane_id },
            .{ .name = "TELAR_PANE_GENERATION", .value = pane_generation },
            .{ .name = "TELAR_WORKSPACE_ID", .value = workspace_id },
            .{ .name = "TELAR_TAB_ID", .value = tab_id },
            .{ .name = "TELAR_BIN_PATH", .value = executable_path },
        };
        return &self.entries;
    }
};
