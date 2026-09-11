const SchedulerType = @import("telar-client").Scheduler;
const bar_updates = @import("bar_updates.zig");
const CommandExecution = @import("CommandExecution.zig");
const Synchronization = @import("Synchronization.zig");
const std = @import("std");
const PositionType = @import("telar-client").Position;
const DueInput = @import("DueInput.zig");
const Due = @import("Due.zig");
const State = @This();

scheduler: SchedulerType = .{},
generation: u64 = 0,
deadlines: [bar_updates.position_count]u64 = @splat(bar_updates.no_deadline),
pending_callbacks: u8 = 0,
pending_commands: u8 = 0,
command_execution: ?CommandExecution = null,
next_command_execution_id: u64 = 1,

pub fn synchronize(state: *State, input: Synchronization) void {
    state.generation = input.generation;
    state.deadlines = @splat(bar_updates.no_deadline);
    state.pending_callbacks = 0;
    state.pending_commands = 0;
    const configuration = input.configuration orelse return;

    for (std.enums.values(PositionType)) |position| {
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
    for (std.enums.values(PositionType)) |position| {
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

pub fn reserveCommand(state: *State, generation: u64, position: PositionType) !CommandExecution {
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
