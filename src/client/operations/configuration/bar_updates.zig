//! Owns configured bar ticks, bounded Lua evaluation and command workers.

const bar_update = @import("bar_update.zig");
const data = @import("model");
const client_diagnostic = @import("client_diagnostic.zig");
const BarUpdateFailure = @import("BarUpdateFailure.zig");
const core = @import("telar-core");
const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const BarUpdatesCompletion = @import("../../bars/BarUpdatesCompletion.zig");
const CallbackRequest = @import("CallbackRequest.zig");
const CommandOutput = @import("CommandOutput.zig");
const BarCommandFailure = @import("BarCommandFailure.zig");
const BarUpdateCommand = @import("BarUpdateCommand.zig");
const BarCallbackContextType = @import("../../config/BarCallbackContext.zig");
const BarMetricsType = @import("../../config/BarMetrics.zig");

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
    try client.timers.rearmBars(client.io, &client.model.bar_updates);
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

fn callbackContext(client: *const Client, output: ?[]const u8) BarCallbackContextType {
    const local = client.clock.localTime();
    const metrics: ?BarMetricsType = if (client.model.systemMetrics()) |value| .{
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
        client.bar_runner.start(.{ .execution_id = execution.id, .command = source.command }) catch |err| {
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
    const state = client.model.barState();
    if (command.generation != client.model.configurationGeneration() or
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
