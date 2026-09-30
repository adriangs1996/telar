//! Owns configured bar ticks, bounded Lua evaluation and command workers.
//! The open panel's source and the clock components share the same timer,
//! the same one-callback-per-event budget and the same single command.

const PanelRequest = @import("PanelRequest.zig");
const pacing = @import("pacing");
const bar_update = @import("bar_update.zig");
const local_time = @import("../resources/local_time.zig");
const data = @import("model");
const client_diagnostic = @import("client_diagnostic.zig");
const BarUpdateFailure = @import("BarUpdateFailure.zig");
const std = @import("std");
const Client = @import("../execution/Client.zig");
const Job = @import("../execution/Job.zig").Job;
const BarUpdatesCompletion = @import("../bars/BarUpdatesCompletion.zig");
const Output = @import("../bars/Output.zig");
const BarUpdateCommand = @import("BarUpdateCommand.zig");
const BarCallbackContext = @import("BarCallbackContext.zig");
const BarMetrics = @import("BarMetrics.zig");

pub const no_deadline = data.bar_timing.no_deadline;
pub const position_count = data.bar_timing.position_count;

pub const CommandExecutionId = data.command_execution.Id;

/// Completes one replaceable timer and folds all expired source ticks.
///
/// ```zig
/// try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !void {
    try client.model.bar_updates.scheduler.complete(result);
    const generation = client.lua_generation orelse {
        try synchronizeBars(client);
        return;
    };
    const configuration = barConfiguration(client) orelse {
        try synchronizeBars(client);
        return;
    };
    const state = &client.model.bar_updates;
    const due = state.takeDue(.{
        .generation = generation.number,
        .configuration = configuration,
        .now_ns = pacing.clock.monotonic(client.io),
        .panel_source = openPanelSource(client, configuration),
    });

    state.pending_callbacks |= due.dynamic_mask;
    state.pending_commands |= due.command_mask;
    state.pending_panel_callback = state.pending_panel_callback or due.panel_callback;
    state.pending_panel_command = state.pending_panel_command or due.panel_command;
    if (due.clock) {
        advanceClock(client);
    }

    try invokeNextCallback(client, configuration);
    try startNextCommand(client);
    try rearm(client);
}

/// Resolves one command worker by exact identity and discards stale generations.
///
/// ```zig
/// try completeCommand(client, completion);
/// ```
pub fn completeCommand(client: *Client, completion: BarUpdatesCompletion) !void {
    defer releaseOutput(completion.result);
    const execution = client.model.bar_updates.finishCommand(completion.execution_id) orelse return;
    const generation = client.lua_generation;
    const configuration = barConfiguration(client);
    if (generation != null and configuration != null and generation.?.number == execution.generation) {
        switch (execution.target) {
            .bar => |position| try completeBarCommand(client, .{
                .execution = execution,
                .position = position,
                .configuration = configuration.?,
                .result = completion.result,
            }),
            .panel => |run| try completePanelCommand(client, .{
                .execution = execution,
                .run = run,
                .configuration = configuration.?,
                .result = completion.result,
            }),
        }
    }

    try startNextCommand(client);
}

/// Opens or closes a configured panel for an `open_panel` action. A panel
/// opened by a key binding appears above the bar component that opens it.
///
/// ```zig
/// try bar_updates.togglePanel(client, .{ .index = 0, .anchor = null });
/// ```
pub fn togglePanel(client: *Client, request: PanelRequest) !void {
    const configuration = barConfiguration(client) orelse return;
    const definition = configuration.panel(request.index) orelse return;
    data.bar_panels.toggle(&client.model, .{
        .target = .{ .configured = request.index },
        .anchor = request.anchor orelse data.bar_panels.anchorFor(&client.model.bars.layout, request.index),
        .source = &definition.source,
        .now_ns = pacing.clock.monotonic(client.io),
    });

    try rearm(client);
}

/// Opens or closes the list of components a narrow bar had no room for.
/// Example: `try bar_updates.toggleOverflow(client);`
pub fn toggleOverflow(client: *Client) !void {
    data.bar_panels.toggle(&client.model, .{
        .target = .overflow,
        .now_ns = pacing.clock.monotonic(client.io),
    });

    try rearm(client);
}

/// Example: `try bar_updates.closePanel(client);`
pub fn closePanel(client: *Client) !void {
    data.bar_panels.close(&client.model);
    try rearm(client);
}

/// Example: `try bar_updates.refreshPanel(client);`
pub fn refreshPanel(client: *Client) !void {
    data.bar_panels.refresh(&client.model, pacing.clock.monotonic(client.io));
    try rearm(client);
}

/// Runs every dynamic and command bar source and the open panel now
/// instead of at their next interval, as after a pick changed what they
/// read. A command already running records one pending rerun.
/// Example: `try bar_updates.refreshSources(client);`
pub fn refreshSources(client: *Client) !void {
    const now_ns = pacing.clock.monotonic(client.io);
    client.model.bar_updates.expire(now_ns);
    data.bar_panels.refresh(&client.model, now_ns);
    try rearm(client);
}

fn completeBarCommand(client: *Client, finished: FinishedBarCommand) !void {
    const source = finished.configuration.source(finished.position);
    if (source.* != .command or source.command.generation != finished.execution.generation) {
        return;
    }

    if (finished.result) |output| {
        try applyCommandOutput(client, .{
            .generation = finished.execution.generation,
            .position = finished.position,
            .command = source.command,
            .output = output.slice(),
        });
    } else |err| {
        _ = try publishFailure(&client.model, .{
            .generation = finished.execution.generation,
            .position = finished.position,
            .reason = err,
            .kind = "command",
        });
    }
}

fn completePanelCommand(client: *Client, finished: FinishedPanelCommand) !void {
    const definition = finished.configuration.panel(finished.run.index) orelse return;
    if (definition.source != .command or definition.source.command.generation != finished.execution.generation) {
        return;
    }

    const output = finished.result catch |err| {
        var diagnostic: data.Diagnostic = .{};
        diagnostic.set("panel '{s}' command failed: {s}", .{ definition.heading.name(), @errorName(err) });
        return failPanel(client, .{
            .generation = finished.execution.generation,
            .run = finished.run,
            .reason = err,
            .diagnostic = diagnostic,
        });
    };

    try renderPanel(client, .{
        .generation = finished.execution.generation,
        .run = finished.run,
        .render = definition.source.command.render,
        .output = output.slice(),
    });
}

fn renderPanel(client: *Client, request: PanelRender) !void {
    var content: data.PanelContent = .{};
    var diagnostic: data.Diagnostic = .{};
    const reference = request.render orelse {
        if (request.output) |text| {
            _ = content.append(.{
                .kind = .text,
                .text = text,
            }) catch |err| return failPanel(client, .{
                .generation = request.generation,
                .run = request.run,
                .reason = err,
                .diagnostic = diagnostic,
            });
        }

        return receivePanel(client, request, content);
    };
    const generation = client.lua_generation orelse return;
    generation.invokeBar(.{
        .reference = reference,
        .context = callbackContext(client, request.output),
        .surface = .panel,
    }, &content, &diagnostic) catch |err| {
        if (diagnostic.len == 0) {
            diagnostic.set("panel callback failed: {s}", .{@errorName(err)});
        }

        return failPanel(client, .{
            .generation = request.generation,
            .run = request.run,
            .reason = err,
            .diagnostic = diagnostic,
        });
    };

    try receivePanel(client, request, content);
}

fn receivePanel(client: *Client, request: PanelRender, content: data.PanelContent) !void {
    const receipt = data.bar_panels.receive(&client.model, .{
        .generation = request.generation,
        .run = request.run,
        .content = content,
        .time = local_time.now(),
    });
    if (receipt == .stale) {
        return;
    }

    const state = &client.model.bar_updates;
    if (state.panel_failed_revision) |revision| {
        if (client.model.diagnostic_revision == revision) {
            _ = data.client_diagnostic.clear(&client.model);
        }

        state.panel_failed_revision = null;
    }
}

fn failPanel(client: *Client, failure: PanelFailure) !void {
    if (data.bar_panels.fail(&client.model, failure.generation, failure.run) == .stale) {
        return;
    }

    _ = try client_diagnostic.replace(&client.model, .{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "panel source failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });
    client.model.bars.panel.reason = client.model.client_diagnostic;
    client.model.bar_updates.panel_failed_revision = client.model.diagnostic_revision;
}

fn invokeCallback(client: *Client, request: CallbackRequest) !bar_update.Outcome {
    const generation = client.lua_generation orelse return .stale;
    var diagnostic: data.Diagnostic = .{};
    var content: data.Content = .{};
    generation.invokeBar(.{
        .reference = request.reference,
        .context = callbackContext(client, request.output),
    }, &content, &diagnostic) catch |err| {
        if (diagnostic.len == 0) {
            diagnostic.set("bar callback failed: {s}", .{@errorName(err)});
        }

        return publishEvaluation(&client.model, .{
            .generation = request.reference.generation,
            .position = request.position,
            .result = .{ .failed = .{ .reason = err, .diagnostic = diagnostic } },
        });
    };

    return publishEvaluation(&client.model, .{
        .generation = request.reference.generation,
        .position = request.position,
        .result = .{ .content = content },
    });
}

fn applyCommandOutput(client: *Client, completed: CommandOutput) !void {
    if (completed.command.render) |reference| {
        _ = try invokeCallback(client, .{
            .position = completed.position,
            .reference = reference,
            .output = completed.output,
        });
        return;
    }

    var content: data.Content = .{};
    if (completed.output.len != 0) {
        try content.appendSegment(.{ .text = completed.output });
    }
    _ = try publishEvaluation(&client.model, .{
        .generation = completed.generation,
        .position = completed.position,
        .result = .{ .content = content },
    });
}

fn publishFailure(model: *data.ClientModel, failure: BarCommandFailure) !bar_update.Outcome {
    var diagnostic: data.Diagnostic = .{};
    diagnostic.set(
        "bar {s} at {s} failed: {s}",
        .{ failure.kind, @tagName(failure.position), @errorName(failure.reason) },
    );

    return publishEvaluation(model, .{
        .generation = failure.generation,
        .position = failure.position,
        .result = .{ .failed = .{
            .reason = failure.reason,
            .diagnostic = diagnostic,
        } },
    });
}

fn publishEvaluation(model: *data.ClientModel, command: BarUpdateCommand) !bar_update.Outcome {
    return switch (command.result) {
        .content => |content| commitContent(model, command, content),
        .failed => |failure| commitFailure(model, command, failure),
    };
}

/// The immutable table a render or pick callback receives; `output` is the
/// command's output when one ran.
/// Example: `const context = bar_updates.callbackContext(client, output);`
pub fn callbackContext(client: *const Client, output: ?[]const u8) BarCallbackContext {
    const local = local_time.now();
    const metrics: ?BarMetrics = if (client.model.system_metrics) |value| .{
        .cpu_percent = value.cpu_percent,
        .memory_used_decigib = value.memory_used_decigib,
        .battery_percent = value.battery_percent,
    } else null;

    return .{
        .client = data.plugin_action.callbackContext(&client.model),
        .time = .{
            .unix_seconds = @intCast(std.Io.Timestamp.now(client.io, .real).toSeconds()),
            .year = local.year,
            .month = local.month,
            .day = local.day,
            .hour = local.hour,
            .minute = local.minute,
            .second = local.second,
            .weekday = local.weekday,
        },
        .metrics = metrics,
        .command_output = output,
        .pane_title = data.pane_title.focusedTitle(&client.model),
    };
}

/// Runs one pending render per event: bar positions first, then the panel.
fn invokeNextCallback(client: *Client, configuration: *const data.BarConfiguration) !void {
    const state = &client.model.bar_updates;
    for (std.enums.values(data.bar_values.Position)) |position| {
        if (state.pending_callbacks & position.bit() == 0) {
            continue;
        }

        state.pending_callbacks &= ~position.bit();
        const source = configuration.source(position);
        if (source.* != .dynamic) {
            continue;
        }

        _ = try invokeCallback(client, .{
            .position = position,
            .reference = source.dynamic.callback,
        });
        return;
    }

    if (!state.pending_panel_callback) {
        return;
    }

    state.pending_panel_callback = false;
    const run = state.panel_run orelse return;
    const definition = configuration.panel(run.index) orelse return;
    if (definition.source != .dynamic) {
        return;
    }

    try renderPanel(client, .{
        .generation = definition.source.dynamic.callback.generation,
        .run = run,
        .render = definition.source.dynamic.callback,
    });
}

fn startNextCommand(client: *Client) !void {
    const state = &client.model.bar_updates;
    if (state.command_execution != null) {
        return;
    }
    const generation = client.lua_generation orelse return;
    const configuration = barConfiguration(client) orelse return;

    for (std.enums.values(data.bar_values.Position)) |position| {
        if (state.pending_commands & position.bit() == 0) {
            continue;
        }

        state.pending_commands &= ~position.bit();
        const source = configuration.source(position);
        if (source.* != .command) {
            continue;
        }

        return startCommand(client, .{
            .generation = generation.number,
            .target = .{ .bar = position },
            .command = source.command,
        });
    }

    if (!state.pending_panel_command) {
        return;
    }

    state.pending_panel_command = false;
    const run = state.panel_run orelse return;
    const definition = configuration.panel(run.index) orelse return;
    if (definition.source != .command) {
        return;
    }

    try startCommand(client, .{
        .generation = generation.number,
        .target = .{ .panel = run },
        .command = definition.source.command,
    });
}

fn startCommand(client: *Client, start: CommandStart) !void {
    const state = &client.model.bar_updates;
    const execution = try state.reserveCommand(start.generation, start.target);
    client.to_background.push(.{ .bar_command = .{ .execution_id = execution.id, .command = start.command } }) catch |err| {
        state.command_execution = null;
        return err;
    };
}

fn commitContent(model: *data.ClientModel, command: BarUpdateCommand, content: data.Content) !bar_update.Outcome {
    const update_commit = data.configurable_bars.update(model, .{
        .generation = command.generation,
        .position = command.position,
        .content = content,
    }) catch |err| switch (err) {
        error.StaleBarUpdate, error.InvalidBarUpdateTarget => return .stale,
    };

    const state = &model.bar_updates;
    if (state.failed_position == command.position) {
        if (model.diagnostic_revision == state.failed_revision) {
            _ = data.client_diagnostic.clear(model);
        }

        state.failed_position = null;
    }

    return if (update_commit) |value| .{ .updated = value } else .unchanged;
}

fn commitFailure(model: *data.ClientModel, command: BarUpdateCommand, failure: BarUpdateFailure) !bar_update.Outcome {
    const state = &model.bars;
    if (command.generation != model.configuration_generation or
        state.layout.generation != command.generation or
        !state.layout.isLive(command.position))
    {
        return .stale;
    }

    _ = try client_diagnostic.replace(model, .{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "bar source failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });
    model.bar_updates.failed_position = command.position;
    model.bar_updates.failed_revision = model.diagnostic_revision;

    return .{ .failed = failure.reason };
}

/// Shows the current local time in clock components and arms the next
/// minute (or second) only while the layout has a clock.
fn advanceClock(client: *Client) void {
    const now = local_time.now();
    const state = &client.model.bar_updates;
    const period = data.bar_clock.period(&client.model.bars.layout) orelse {
        state.scheduleClock(no_deadline);
        return;
    };

    if (!std.meta.eql(client.model.bars.now, now)) {
        client.model.bars.now = now;
        client.model.bars_revision +%= 1;
    }

    state.scheduleClock(pacing.clock.monotonic(client.io) + data.bar_clock.untilNext(period, now));
}

fn openPanelSource(client: *const Client, configuration: *const data.BarConfiguration) ?*const data.bar_values.Source {
    const run = client.model.bar_updates.panel_run orelse return null;
    const definition = configuration.panel(run.index) orelse return null;
    return &definition.source;
}

fn releaseOutput(result: anyerror!Output) void {
    var output = result catch return;
    output.deinit();
}

/// Keeps one timer for the earliest bar deadline or an immediate pending
/// callback. A timer the queue rejects releases its reservation so the next
/// attempt can retry.
/// Example: `try bar_updates.rearm(client);`
pub fn rearm(client: *Client) !void {
    const state = &client.model.bar_updates;
    const job = timerJob(client.io, state) orelse return;

    client.to_workers.push(job) catch |err| {
        state.scheduler.schedulingFailed();

        return err;
    };
}

/// The timer the bar deadlines need, or null while the pending one still
/// fits or nothing is due.
fn timerJob(io: std.Io, state: *data.BarUpdatesState) ?Job {
    const immediate = state.pending_callbacks != 0 or state.pending_panel_callback;
    const deadline_ns = if (immediate) pacing.clock.monotonic(io) else state.nextDeadline();

    return switch (state.scheduler.update(io, deadline_ns)) {
        .idle, .retained => null,
        .schedule => .{ .timer = .{ .kind = .bar, .scheduler = &state.scheduler } },
    };
}

test "bar timers reuse one pending worker and follow the earliest deadline" {
    var state: data.BarUpdatesState = .{};
    const io = std.testing.io;
    try std.testing.expect(timerJob(io, &state) == null);

    state.pending_callbacks = data.bar_values.Position.bottom_left.bit();
    const first = timerJob(io, &state).?;
    try std.testing.expectEqual(Job.Kind.bar, first.timer.kind);
    try std.testing.expect(state.scheduler.pending);
    const immediate = state.scheduler.deadline_ns.load(.acquire);
    try std.testing.expect(immediate <= pacing.clock.monotonic(io));
    try std.testing.expect(timerJob(io, &state) == null);

    state.pending_callbacks = 0;
    state.deadlines[@intFromEnum(data.bar_values.Position.bottom_left)] = immediate + std.time.ns_per_s;
    try std.testing.expect(timerJob(io, &state) == null);
    try std.testing.expectEqual(immediate + std.time.ns_per_s, state.scheduler.deadline_ns.load(.acquire));
    state.synchronize(
        .{
            .generation = 2,
            .configuration = null,
            .now_ns = pacing.clock.monotonic(io),
        },
    );
    try std.testing.expect(timerJob(io, &state) == null);
    try std.testing.expectEqual(data.bar_timing.no_deadline, state.scheduler.deadline_ns.load(.acquire));
    try state.scheduler.complete({});
    try std.testing.expect(timerJob(io, &state) == null);
    try std.testing.expect(!state.scheduler.pending);
}

const BarCommandFailure = struct {
    generation: u64,
    position: data.bar_values.Position,
    reason: anyerror,
    kind: []const u8,
};

const CallbackRequest = struct {
    position: data.bar_values.Position,
    reference: data.CallbackRef,
    output: ?[]const u8 = null,
};

const CommandOutput = struct {
    generation: u64,
    position: data.bar_values.Position,
    command: data.BarCommand,
    output: []const u8,
};

const CommandStart = struct {
    generation: u64,
    target: data.CommandTarget,
    command: data.BarCommand,
};

const FinishedBarCommand = struct {
    execution: data.CommandExecution,
    position: data.bar_values.Position,
    configuration: *const data.BarConfiguration,
    result: anyerror!Output,
};

const FinishedPanelCommand = struct {
    execution: data.CommandExecution,
    run: data.PanelRun,
    configuration: *const data.BarConfiguration,
    result: anyerror!Output,
};

const PanelRender = struct {
    generation: u64,
    run: data.PanelRun,
    render: ?data.CallbackRef,
    output: ?[]const u8 = null,
};

const PanelFailure = struct {
    generation: u64,
    run: data.PanelRun,
    reason: anyerror,
    diagnostic: data.Diagnostic,
};

/// Borrows bar sources only when Lua and the model agree on their generation.
/// Example: `const configuration = bar_updates.barConfiguration(client) orelse return;`
pub fn barConfiguration(client: *const Client) ?*const data.BarConfiguration {
    const generation = client.lua_generation orelse return null;

    if (generation.number != client.model.configuration_generation) {
        return null;
    }

    return &generation.snapshot.bars;
}

/// Replaces bar deadlines from the active configuration and rearms their timer.
/// Example: `try bar_updates.synchronizeBars(client);`
pub fn synchronizeBars(client: *Client) !void {
    client.model.bar_updates.synchronize(
        .{
            .generation = if (client.lua_generation) |generation| generation.number else client.model.configuration_generation,
            .configuration = barConfiguration(client),
            .now_ns = pacing.clock.monotonic(client.io),
        },
    );
    // A reload that kept the layout keeps its open panel; its source starts
    // again under the new generation.
    const panel = &client.model.bars.panel;
    if (panel.configured()) |index| {
        client.model.bar_updates.startPanel(.{
            .index = index,
            .opening = panel.opening,
        }, pacing.clock.monotonic(client.io));
    }
    advanceClock(client);

    try rearm(client);
}
