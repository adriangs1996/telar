const pacing = @import("pacing");
const model = @import("model.zig");
const bar_updates = @import("../operations/configuration/bar_timing.zig");
const CommandExecution = @import("../operations/configuration/CommandExecution.zig");
const Synchronization = @import("../operations/configuration/Synchronization.zig");
const std = @import("std");
const DueInput = @import("../operations/configuration/DueInput.zig");
const Due = @import("../operations/configuration/Due.zig");
const BarUpdatesState = @This();

scheduler: pacing.DeadlineScheduler = .{},
generation: u64 = 0,
deadlines: [bar_updates.position_count]u64 = @splat(bar_updates.no_deadline),
pending_callbacks: u8 = 0,
pending_commands: u8 = 0,
command_execution: ?CommandExecution = null,
next_command_execution_id: u64 = 1,

pub fn synchronize(self: *BarUpdatesState, input: Synchronization) void {
    self.generation = input.generation;
    self.deadlines = @splat(bar_updates.no_deadline);
    self.pending_callbacks = 0;
    self.pending_commands = 0;
    const configuration = input.configuration orelse return;

    for (std.enums.values(model.Position)) |position| {
        if (configuration.source(position).interval() != null) {
            self.deadlines[@intFromEnum(position)] = input.now_ns;
        }
    }
}

pub fn takeDue(self: *BarUpdatesState, input: DueInput) Due {
    if (self.generation != input.generation) {
        return .{};
    }

    var due: Due = .{};
    for (std.enums.values(model.Position)) |position| {
        const index = @intFromEnum(position);
        const deadline_ns = self.deadlines[index];
        if (deadline_ns == bar_updates.no_deadline or deadline_ns > input.now_ns) {
            continue;
        }

        const source = input.configuration.source(position);
        const interval_ns = source.interval() orelse {
            self.deadlines[index] = bar_updates.no_deadline;
            continue;
        };
        self.deadlines[index] = bar_updates.followingDeadline(deadline_ns, interval_ns, input.now_ns);
        switch (source.*) {
            .dynamic => due.dynamic_mask |= position.bit(),
            .command => due.command_mask |= position.bit(),
            else => self.deadlines[index] = bar_updates.no_deadline,
        }
    }

    return due;
}

pub fn nextDeadline(self: *const BarUpdatesState) ?u64 {
    var next: u64 = bar_updates.no_deadline;
    for (self.deadlines) |deadline_ns| {
        next = @min(next, deadline_ns);
    }

    return if (next == bar_updates.no_deadline) null else next;
}

pub fn reserveCommand(self: *BarUpdatesState, generation: u64, position: model.Position) !CommandExecution {
    std.debug.assert(self.command_execution == null);
    if (self.next_command_execution_id == 0) {
        return error.BarCommandExecutionIdExhausted;
    }

    const execution: CommandExecution = .{
        .id = @enumFromInt(self.next_command_execution_id),
        .generation = generation,
        .position = position,
    };
    self.next_command_execution_id +%= 1;
    self.command_execution = execution;

    return execution;
}

pub fn finishCommand(self: *BarUpdatesState, execution_id: bar_updates.CommandExecutionId) ?CommandExecution {
    const execution = self.command_execution orelse return null;
    if (execution.id != execution_id) {
        return null;
    }

    self.command_execution = null;
    return execution;
}
