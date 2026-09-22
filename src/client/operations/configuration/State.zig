const model = @import("../../bars/model.zig");
const timers_module = @import("../../resources/timers.zig");
const core = @import("telar-core");
const bar_updates = @import("bar_updates.zig");
const CommandExecution = @import("CommandExecution.zig");
const Synchronization = @import("Synchronization.zig");
const std = @import("std");
const DueInput = @import("DueInput.zig");
const Due = @import("Due.zig");
const HostTimers = @import("../../resources/HostTimers.zig");
const State = @This();

scheduler: core.DeadlineScheduler = .{},
generation: u64 = 0,
deadlines: [bar_updates.position_count]u64 = @splat(bar_updates.no_deadline),
pending_callbacks: u8 = 0,
pending_commands: u8 = 0,
command_execution: ?CommandExecution = null,
next_command_execution_id: u64 = 1,

/// Keeps one timer for the earliest deadline or an immediate pending callback.
/// A rejected timer releases its reservation so the next attempt can retry.
/// Example: `try state.rearm(io, timers);`
pub fn rearm(self: *State, io: std.Io, timers: HostTimers) !void {
    const deadline_ns = if (self.pending_callbacks != 0) core.monotonic(io) else self.nextDeadline();

    switch (self.scheduler.update(io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => timers.arm(.bar, &self.scheduler) catch |err| {
            self.scheduler.schedulingFailed();

            return err;
        },
    }
}

pub fn synchronize(state: *State, input: Synchronization) void {
    state.generation = input.generation;
    state.deadlines = @splat(bar_updates.no_deadline);
    state.pending_callbacks = 0;
    state.pending_commands = 0;
    const configuration = input.configuration orelse return;

    for (std.enums.values(model.Position)) |position| {
        if (configuration.source(position).interval() != null) {
            state.deadlines[@intFromEnum(position)] = input.now_ns;
        }
    }
}

pub fn takeDue(state: *State, input: DueInput) Due {
    if (state.generation != input.generation) {
        return .{};
    }

    var due: Due = .{};
    for (std.enums.values(model.Position)) |position| {
        const index = @intFromEnum(position);
        const deadline_ns = state.deadlines[index];
        if (deadline_ns == bar_updates.no_deadline or deadline_ns > input.now_ns) {
            continue;
        }

        const source = input.configuration.source(position);
        const interval_ns = source.interval() orelse {
            state.deadlines[index] = bar_updates.no_deadline;
            continue;
        };
        state.deadlines[index] = bar_updates.followingDeadline(deadline_ns, interval_ns, input.now_ns);
        switch (source.*) {
            .dynamic => due.dynamic_mask |= position.bit(),
            .command => due.command_mask |= position.bit(),
            else => state.deadlines[index] = bar_updates.no_deadline,
        }
    }

    return due;
}

pub fn nextDeadline(state: *const State) ?u64 {
    var next: u64 = bar_updates.no_deadline;
    for (state.deadlines) |deadline_ns| {
        next = @min(next, deadline_ns);
    }

    return if (next == bar_updates.no_deadline) null else next;
}

pub fn reserveCommand(state: *State, generation: u64, position: model.Position) !CommandExecution {
    std.debug.assert(state.command_execution == null);
    if (state.next_command_execution_id == 0) {
        return error.BarCommandExecutionIdExhausted;
    }

    const execution: CommandExecution = .{
        .id = @enumFromInt(state.next_command_execution_id),
        .generation = generation,
        .position = position,
    };
    state.next_command_execution_id +%= 1;
    state.command_execution = execution;

    return execution;
}

pub fn finishCommand(state: *State, execution_id: bar_updates.CommandExecutionId) ?CommandExecution {
    const execution = state.command_execution orelse return null;
    if (execution.id != execution_id) {
        return null;
    }

    state.command_execution = null;
    return execution;
}

test "bar timer scheduling retries failure and reuses one pending worker" {
    const Timer = struct {
        reject: bool = true,
        calls: usize = 0,

        fn arm(raw: *anyopaque, kind: timers_module.Kind, scheduler: *core.DeadlineScheduler) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(.bar, kind);
            try std.testing.expect(scheduler.pending);

            if (self.reject) {
                return error.TimerBusy;
            }
        }
    };

    var timer: Timer = .{};
    const timers: HostTimers = .{
        .context = &timer,
        .arm_fn = Timer.arm,
    };
    var state: State = .{};
    const io = std.testing.io;
    try state.rearm(io, timers);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    state.pending_callbacks = model.Position.bottom_left.bit();
    try std.testing.expectError(error.TimerBusy, state.rearm(io, timers));
    try std.testing.expect(!state.scheduler.pending);
    timer.reject = false;
    try state.rearm(io, timers);
    try std.testing.expect(state.scheduler.pending);
    const immediate = state.scheduler.deadline_ns.load(.acquire);
    try std.testing.expect(immediate <= core.monotonic(io));
    try state.rearm(io, timers);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);

    state.pending_callbacks = 0;
    state.deadlines[@intFromEnum(model.Position.bottom_left)] = immediate + std.time.ns_per_s;
    try state.rearm(io, timers);
    try std.testing.expectEqual(immediate + std.time.ns_per_s, state.scheduler.deadline_ns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    state.synchronize(
        .{
            .generation = 2,
            .configuration = null,
            .now_ns = core.monotonic(io),
        },
    );
    try state.rearm(io, timers);
    try std.testing.expectEqual(bar_updates.no_deadline, state.scheduler.deadline_ns.load(.acquire));
    try state.scheduler.complete({});
    try state.rearm(io, timers);
    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    try std.testing.expect(!state.scheduler.pending);
}
