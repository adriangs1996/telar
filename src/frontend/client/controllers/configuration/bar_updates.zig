//! Owns configured bar ticks, bounded Lua evaluation and command workers.

const std = @import("std");
const bars = @import("../../../bars/root.zig");
const lua_config = @import("../../../config/root.zig");
const platform = @import("../../../platform/root.zig");
const configuration_application = @import("telar-client").application.configuration;
const client_clock = @import("telar-client").resources.clock;
const deadline_timer = @import("telar-client").resources.deadline_timer;

const Client = @import("../../Client.zig");
const apply_bar_update = configuration_application.bar_update;
pub const no_deadline: u64 = std.math.maxInt(u64);
pub const position_count = @typeInfo(bars.Position).@"enum".fields.len;

pub const CommandExecutionId = enum(u64) {
    none = 0,
    _,
};

pub const Completion = @import("BarUpdatesCompletion.zig");

const CommandExecution = @import("CommandExecution.zig");

const Job = @import("BarUpdatesJob.zig");

const Synchronization = @import("Synchronization.zig");

const DueInput = @import("DueInput.zig");

const Due = @import("Due.zig");

pub const State = @import("State.zig");

/// Replaces all deadlines from the active typed configuration generation.
///
/// ```zig
/// try synchronize(client);
/// ```
pub fn synchronize(client: *Client) !void {
    const generation = client.lua_generation;
    const configuration = activeConfiguration(client);
    client.bar_updates.synchronize(.{
        .generation = if (generation) |value| value.number else client.model.configurationGeneration(),
        .configuration = configuration,
        .now_ns = client_clock.monotonic(client.io),
    });

    try rearm(client);
}

/// Completes one replaceable timer and folds all expired source ticks.
///
/// ```zig
/// try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !void {
    try client.bar_updates.scheduler.complete(result);
    const generation = client.lua_generation orelse {
        try synchronize(client);
        return;
    };
    const configuration = activeConfiguration(client) orelse {
        try synchronize(client);
        return;
    };
    const due = client.bar_updates.takeDue(.{
        .generation = generation.number,
        .configuration = configuration,
        .now_ns = client_clock.monotonic(client.io),
    });

    client.bar_updates.pending_callbacks |= due.dynamic_mask;
    client.bar_updates.pending_commands |= due.command_mask;
    try invokeNextCallback(client, configuration);
    try startNextCommand(client);
    try rearm(client);
}

/// Resolves one command worker by exact identity and discards stale generations.
///
/// ```zig
/// try completeCommand(client, completion);
/// ```
pub fn completeCommand(client: *Client, completion: Completion) !void {
    const execution = client.bar_updates.finishCommand(completion.execution_id) orelse return;
    const generation = client.lua_generation;
    const configuration = activeConfiguration(client);
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

const CallbackRequest = @import("CallbackRequest.zig");

fn invokeCallback(client: *Client, request: CallbackRequest) !apply_bar_update.Outcome {
    const generation = client.lua_generation orelse return .stale;
    var diagnostic: lua_config.Diagnostic = .{};
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

const CommandOutput = @import("CommandOutput.zig");

fn applyCommandOutput(client: *Client, completed: CommandOutput) !void {
    if (completed.command.render) |reference| {
        _ = try invokeCallback(client, .{
            .position = completed.execution.position,
            .reference = reference,
            .output = completed.output.slice(),
        });
        return;
    }

    var content: bars.Content = .{};
    if (completed.output.len != 0) {
        try content.append(.{ .text = completed.output.slice() });
    }
    _ = try publishEvaluation(client, .{
        .generation = completed.execution.generation,
        .position = completed.execution.position,
        .result = .{ .content = content },
    });
}

const Failure = @import("Failure.zig");

fn publishFailure(client: *Client, failure: Failure) !apply_bar_update.Outcome {
    var diagnostic: lua_config.Diagnostic = .{};
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

fn publishEvaluation(client: *Client, command: apply_bar_update.Command) !apply_bar_update.Outcome {
    var handler: apply_bar_update.ApplyBarUpdateHandler = .{ .model = &client.model };

    return handler.execute(command);
}

fn callbackContext(client: *const Client, output: ?[]const u8) lua_config.BarCallbackContext {
    const local = platform.localTime();
    const metrics: ?lua_config.BarMetrics = if (client.model.systemMetrics()) |value| .{
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

fn activeConfiguration(client: *const Client) ?*const bars.Configuration {
    const generation = client.lua_generation orelse return null;
    if (generation.number != client.model.configurationGeneration()) {
        return null;
    }

    return &generation.snapshot.bars;
}

fn invokeNextCallback(client: *Client, configuration: *const bars.Configuration) !void {
    for (std.enums.values(bars.Position)) |position| {
        if (client.bar_updates.pending_callbacks & position.bit() == 0) {
            continue;
        }

        client.bar_updates.pending_callbacks &= ~position.bit();
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
    if (client.bar_updates.command_execution != null) {
        return;
    }
    const generation = client.lua_generation orelse return;
    const configuration = activeConfiguration(client) orelse return;

    for (std.enums.values(bars.Position)) |position| {
        if (client.bar_updates.pending_commands & position.bit() == 0) {
            continue;
        }

        client.bar_updates.pending_commands &= ~position.bit();
        const source = configuration.source(position);
        if (source.* != .command) {
            continue;
        }

        const execution = try client.bar_updates.reserveCommand(generation.number, position);
        client.select.concurrent(.bar_command, executeCommand, .{
            client.io,
            Job{ .execution_id = execution.id, .command = source.command },
        }) catch |err| {
            client.bar_updates.command_execution = null;
            return err;
        };
        return;
    }
}

fn executeCommand(io: std.Io, job: Job) Completion {
    return .{
        .execution_id = job.execution_id,
        .result = bars.command.run(io, job.command),
    };
}

fn rearm(client: *Client) !void {
    const scheduler = &client.bar_updates.scheduler;
    const deadline_ns = if (client.bar_updates.pending_callbacks != 0)
        client_clock.monotonic(client.io)
    else
        client.bar_updates.nextDeadline();
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.select.concurrent(.bar_tick, deadline_timer.wait, .{
            client.io,
            scheduler,
        }) catch |err| {
            scheduler.schedulingFailed();
            return err;
        },
    }
}

pub fn followingDeadline(deadline_ns: u64, interval_ns: u64, now_ns: u64) u64 {
    std.debug.assert(interval_ns != 0);
    const elapsed = now_ns - deadline_ns;
    const skipped = elapsed / interval_ns;
    const increment = std.math.mul(u64, skipped + 1, interval_ns) catch return no_deadline;

    return deadline_ns +| increment;
}

test "bar deadlines start immediately and coalesce elapsed intervals" {
    const configuration: bars.Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 4, .id = 0 }, .interval_ns = 100 } },
            .{ .command = .{ .generation = 4, .interval_ns = 250, .timeout_ms = 100 } },
            .tabs,
        },
    };
    var state: State = .{};
    state.synchronize(.{ .generation = 4, .configuration = &configuration, .now_ns = 1_000 });

    try std.testing.expectEqual(@as(?u64, 1_000), state.nextDeadline());
    const due = state.takeDue(.{
        .generation = 4,
        .configuration = &configuration,
        .now_ns = 1_750,
    });

    try std.testing.expectEqual(bars.Position.bottom_left.bit(), due.dynamic_mask);
    try std.testing.expectEqual(bars.Position.bottom_center.bit(), due.command_mask);
    try std.testing.expectEqual(@as(u64, 1_800), state.deadlines[@intFromEnum(bars.Position.bottom_left)]);
    try std.testing.expectEqual(@as(u64, 2_000), state.deadlines[@intFromEnum(bars.Position.bottom_center)]);
}

test "bar synchronization clears queued work but preserves one in-flight command identity" {
    var state: State = .{};
    state.pending_callbacks = bars.Position.top_right.bit();
    state.pending_commands = bars.Position.bottom_left.bit();
    const execution = try state.reserveCommand(3, .bottom_left);

    state.synchronize(.{ .generation = 4, .configuration = null, .now_ns = 2_000 });

    try std.testing.expectEqual(@as(u8, 0), state.pending_callbacks);
    try std.testing.expectEqual(@as(u8, 0), state.pending_commands);
    try std.testing.expectEqual(execution, state.command_execution.?);
    try std.testing.expectEqual(execution, state.finishCommand(execution.id).?);
    try std.testing.expect(state.command_execution == null);
}
