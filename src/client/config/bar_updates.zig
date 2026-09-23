//! Owns configured bar ticks, bounded Lua evaluation and command workers.

const bar_update = @import("bar_update.zig");
const local_time = @import("../resources/local_time.zig");
const data = @import("model");
const client_diagnostic = @import("client_diagnostic.zig");
const BarUpdateFailure = @import("BarUpdateFailure.zig");
const core = @import("telar-core");
const std = @import("std");
const Client = @import("../AttachedClient.zig");
const Workers = @import("../execution/Workers.zig");
const Job = @import("../execution/Job.zig").Job;
const BarUpdatesCompletion = @import("../bars/BarUpdatesCompletion.zig");
const CommandOutput = @import("CommandOutput.zig");
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
        try client.synchronizeBars();
        return;
    };
    const configuration = client.barConfiguration() orelse {
        try client.synchronizeBars();
        return;
    };
    const due = client.model.bar_updates.takeDue(.{
        .generation = generation.number,
        .configuration = configuration,
        .now_ns = core.monotonic(client.io),
    });

    client.model.bar_updates.pending_callbacks |= due.dynamic_mask;
    client.model.bar_updates.pending_commands |= due.command_mask;
    try invokeNextCallback(client, configuration);
    try startNextCommand(client);
    try rearm(client.workers, client.io, &client.model.bar_updates);
}

/// Resolves one command worker by exact identity and discards stale generations.
///
/// ```zig
/// try completeCommand(client, completion);
/// ```
pub fn completeCommand(client: *Client, completion: BarUpdatesCompletion) !void {
    const execution = client.model.bar_updates.finishCommand(completion.execution_id) orelse return;
    const generation = client.lua_generation;
    const configuration = client.barConfiguration();
    if (generation != null and configuration != null and generation.?.number == execution.generation) {
        const source = configuration.?.source(execution.position);
        if (source.* == .command and source.command.generation == execution.generation) {
            if (completion.result) |output| {
                try applyCommandOutput(client, .{
                    .execution = execution,
                    .command = source.command,
                    .output = output,
                });
            } else |err| {
                _ = try publishFailure(client, .{
                    .generation = execution.generation,
                    .position = execution.position,
                    .reason = err,
                    .kind = "command",
                });
            }
        }
    }

    try startNextCommand(client);
}

fn invokeCallback(client: *Client, request: CallbackRequest) !bar_update.Outcome {
    const generation = client.lua_generation orelse return .stale;
    var diagnostic: data.Diagnostic = .{};
    const content = generation.invokeBar(.{
        .reference = request.reference,
        .context = callbackContext(client, request.output),
    }, &diagnostic) catch |err| {
        if (diagnostic.len == 0) {
            diagnostic.set("bar callback failed: {s}", .{@errorName(err)});
        }

        return publishEvaluation(client, .{
            .generation = request.reference.generation,
            .position = request.position,
            .result = .{ .failed = .{ .reason = err, .diagnostic = diagnostic } },
        });
    };

    return publishEvaluation(client, .{
        .generation = request.reference.generation,
        .position = request.position,
        .result = .{ .content = content },
    });
}

fn applyCommandOutput(client: *Client, completed: CommandOutput) !void {
    if (completed.command.render) |reference| {
        _ = try invokeCallback(client, .{
            .position = completed.execution.position,
            .reference = reference,
            .output = completed.output.slice(),
        });
        return;
    }

    var content: data.Content = .{};
    if (completed.output.len != 0) {
        try content.append(.{ .text = completed.output.slice() });
    }
    _ = try publishEvaluation(client, .{
        .generation = completed.execution.generation,
        .position = completed.execution.position,
        .result = .{ .content = content },
    });
}

fn publishFailure(client: *Client, failure: BarCommandFailure) !bar_update.Outcome {
    var diagnostic: data.Diagnostic = .{};
    diagnostic.set(
        "bar {s} at {s} failed: {s}",
        .{ failure.kind, @tagName(failure.position), @errorName(failure.reason) },
    );

    return publishEvaluation(client, .{
        .generation = failure.generation,
        .position = failure.position,
        .result = .{ .failed = .{
            .reason = failure.reason,
            .diagnostic = diagnostic,
        } },
    });
}

fn publishEvaluation(client: *Client, command: BarUpdateCommand) !bar_update.Outcome {
    return switch (command.result) {
        .content => |content| commitContent(client, command, content),
        .failed => |failure| commitFailure(client, command, failure),
    };
}

fn callbackContext(client: *const Client, output: ?[]const u8) BarCallbackContext {
    const local = local_time.now();
    const metrics: ?BarMetrics = if (client.model.system_metrics) |value| .{
        .cpu_percent = value.cpu_percent,
        .memory_used_decigib = value.memory_used_decigib,
        .battery_percent = value.battery_percent,
    } else null;

    return .{
        .client = client.model.callbackContext(),
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
        .pane_title = client.model.focusedPaneTitle(),
    };
}

fn invokeNextCallback(client: *Client, configuration: *const data.BarConfiguration) !void {
    for (std.enums.values(data.bar_values.Position)) |position| {
        if (client.model.bar_updates.pending_callbacks & position.bit() == 0) {
            continue;
        }

        client.model.bar_updates.pending_callbacks &= ~position.bit();
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
}

fn startNextCommand(client: *Client) !void {
    if (client.model.bar_updates.command_execution != null) {
        return;
    }
    const generation = client.lua_generation orelse return;
    const configuration = client.barConfiguration() orelse return;

    for (std.enums.values(data.bar_values.Position)) |position| {
        if (client.model.bar_updates.pending_commands & position.bit() == 0) {
            continue;
        }

        client.model.bar_updates.pending_commands &= ~position.bit();
        const source = configuration.source(position);
        if (source.* != .command) {
            continue;
        }

        const execution = try client.model.bar_updates.reserveCommand(generation.number, position);
        client.workers.start(.{ .bar_command = .{ .execution_id = execution.id, .command = source.command } }) catch |err| {
            client.model.bar_updates.command_execution = null;
            return err;
        };
        return;
    }
}

fn commitContent(client: *Client, command: BarUpdateCommand, content: data.Content) !bar_update.Outcome {
    const update_commit = client.model.updateBar(.{
        .generation = command.generation,
        .position = command.position,
        .content = content,
    }) catch |err| switch (err) {
        error.StaleBarUpdate, error.InvalidBarUpdateTarget => return .stale,
    };

    return if (update_commit) |value| .{ .updated = value } else .unchanged;
}

fn commitFailure(client: *Client, command: BarUpdateCommand, failure: BarUpdateFailure) !bar_update.Outcome {
    const state = &client.model.bars;
    if (command.generation != client.model.configuration_generation or
        state.layout.generation != command.generation or
        !state.layout.isLive(command.position))
    {
        return .stale;
    }

    _ = try client_diagnostic.replace(&client.model, .{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "bar source failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });

    return .{ .failed = failure.reason };
}

/// Keeps one timer for the earliest bar deadline or an immediate pending
/// callback. A rejected timer releases its reservation so the next attempt
/// can retry.
/// Example: `try bar_updates.rearm(client.workers, client.io, &client.model.bar_updates);`
pub fn rearm(workers: Workers, io: std.Io, state: *data.BarUpdatesState) !void {
    const deadline_ns = if (state.pending_callbacks != 0) core.monotonic(io) else state.nextDeadline();

    switch (state.scheduler.update(io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => workers.start(.{ .timer = .{ .kind = .bar, .scheduler = &state.scheduler } }) catch |err| {
            state.scheduler.schedulingFailed();

            return err;
        },
    }
}

test "bar timer scheduling retries failure and reuses one pending worker" {
    const Timer = struct {
        reject: bool = true,
        calls: usize = 0,

        fn start(raw: *anyopaque, job: Job) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(Job.Kind.bar, job.timer.kind);
            try std.testing.expect(job.timer.scheduler.pending);

            if (self.reject) {
                return error.TimerBusy;
            }
        }
    };

    var timer: Timer = .{};
    const workers: Workers = .{
        .context = &timer,
        .start_fn = Timer.start,
    };
    var state: data.BarUpdatesState = .{};
    const io = std.testing.io;
    try rearm(workers, io, &state);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    state.pending_callbacks = data.bar_values.Position.bottom_left.bit();
    try std.testing.expectError(error.TimerBusy, rearm(workers, io, &state));
    try std.testing.expect(!state.scheduler.pending);
    timer.reject = false;
    try rearm(workers, io, &state);
    try std.testing.expect(state.scheduler.pending);
    const immediate = state.scheduler.deadline_ns.load(.acquire);
    try std.testing.expect(immediate <= core.monotonic(io));
    try rearm(workers, io, &state);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);

    state.pending_callbacks = 0;
    state.deadlines[@intFromEnum(data.bar_values.Position.bottom_left)] = immediate + std.time.ns_per_s;
    try rearm(workers, io, &state);
    try std.testing.expectEqual(immediate + std.time.ns_per_s, state.scheduler.deadline_ns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    state.synchronize(
        .{
            .generation = 2,
            .configuration = null,
            .now_ns = core.monotonic(io),
        },
    );
    try rearm(workers, io, &state);
    try std.testing.expectEqual(data.bar_timing.no_deadline, state.scheduler.deadline_ns.load(.acquire));
    try state.scheduler.complete({});
    try rearm(workers, io, &state);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
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
