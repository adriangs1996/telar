//! Pane launch transaction (ADR 0001).
//!
//! Allocation, proxy registration, process creation, table insertion and
//! actor scheduling either establish a fully observable pane or run the
//! matching rollback path.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const agent_panes = @import("agent_panes.zig");
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

/// Managed agent panes each own a provider process; the bound keeps a
/// runaway client from exhausting them before the pane table fills.
const max_agent_panes = 16;

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
    const fresh = if (request.kind == .agent)
        try launchAgent(model, request)
    else
        try launchTerminal(model, request);

    session_checkpoint.noteChange(model);
    return fresh;
}

/// Narrows a launch failure to the errors requests report to clients.
///
/// ```zig
/// const pane = pane_launch.launch(model, request) catch |err| return pane_launch.requestError(err);
/// ```
pub fn requestError(launch_error: anyerror) anyerror {
    return switch (launch_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
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

fn launchTerminal(model: *RuntimeModel, request: LaunchRequest) !*Pane {
    const proxy = model.resources.proxy.capability();
    const pane_key = try model.panes.allocateKey();
    var pane_overrides: PaneOverrides = .{};
    const identity_overrides = pane_overrides.build(pane_key, request.location, model.socket_path, model.executable_path[0..model.executable_path_len]);
    var proxy_environment: ?PaneEnvironment = null;
    defer if (proxy_environment) |*owned| owned.deinit();
    var owned_environment: ?ChildEnvironment = null;
    defer if (owned_environment) |*owned| owned.deinit();
    var proxy_registered = false;
    errdefer if (proxy_registered) if (proxy) |active|
        active.revokePane(pane_key);

    const child_environment = if (proxy) |active| block: {
        proxy_environment = try active.registerPane(
            pane_key,
            .{
                .inherited = model.inherited_environment,
                .overrides = identity_overrides,
            },
        );
        proxy_registered = true;
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
        .review_service = model.review_service,
        .graphics_budget = &model.panes.graphics_budget,
        .manifests = &model.resources.agent_manifests,
        .environment = model.inherited_environment,
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

    fresh.launch_record.capture(request.launch);
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
    proxy_registered = false;
    return fresh;
}

fn launchAgent(model: *RuntimeModel, request: LaunchRequest) !*Pane {
    var managed_count: usize = 0;
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (pane.kind == .agent) {
            managed_count += 1;
        }
    }

    if (managed_count >= max_agent_panes) {
        return error.PaneLimitReached;
    }

    const key = try model.panes.allocateKey();
    const pane = try Pane.create(.{
        .io = model.io,
        .gpa = model.gpa,
        .history_service = model.resources.history.service(),
        .review_service = model.review_service,
        .graphics_budget = &model.panes.graphics_budget,
        .manifests = &model.resources.agent_manifests,
        .environment = model.inherited_environment,
    }, .{
        .identity = key,
        .location = request.location,
        .kind = .agent,
        .restore_conversation = request.restore_conversation,
        .launch_cwd = request.launch_cwd,
        .workspace_path = request.workspace_path,
        .size = request.size,
        .graphics_limits = model.panes.graphics_limits,
        .terminal_colors = terminal_colors.ofWorkspace(model, request.location.workspace),
    });
    model.panes.insert(pane) catch |err| {
        pane.destroy();
        return err;
    };
    errdefer model.panes.removeAndDestroy(pane);

    _ = pane.beginExitWait();
    errdefer pane.cancelExitWait();

    try model.select.concurrent(.agent_thread_changed, agent_panes.waitForChange, .{ model.io, pane });
    pane.commitLaunch("codex app-server");
    return pane;
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
