const pacing = @import("pacing");
const model = @import("model.zig");
const bar_updates = @import("../operations/configuration/bar_timing.zig");
const CommandExecution = @import("../operations/configuration/CommandExecution.zig");
const Synchronization = @import("../operations/configuration/Synchronization.zig");
const std = @import("std");
const DueInput = @import("../operations/configuration/DueInput.zig");
const Due = @import("../operations/configuration/Due.zig");
const PanelRun = @import("../operations/configuration/PanelRun.zig");
const CommandTarget = @import("../operations/configuration/CommandTarget.zig").CommandTarget;
const BarUpdatesState = @This();

scheduler: pacing.DeadlineScheduler = .{},
generation: u64 = 0,
deadlines: [bar_updates.position_count]u64 = @splat(bar_updates.no_deadline),
pending_callbacks: u8 = 0,
pending_commands: u8 = 0,
command_execution: ?CommandExecution = null,
next_command_execution_id: u64 = 1,
/// The open panel's source runs only while it is open.
panel_run: ?PanelRun = null,
panel_deadline: u64 = bar_updates.no_deadline,
pending_panel_callback: bool = false,
pending_panel_command: bool = false,
/// The next wall-clock minute (or second) a clock component shows.
clock_deadline: u64 = bar_updates.no_deadline,

pub fn synchronize(self: *BarUpdatesState, input: Synchronization) void {
    self.generation = input.generation;
    self.deadlines = @splat(bar_updates.no_deadline);
    self.pending_callbacks = 0;
    self.pending_commands = 0;
    self.stopPanel();
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

    if (self.clock_deadline <= input.now_ns) {
        self.clock_deadline = bar_updates.no_deadline;
        due.clock = true;
    }

    self.takePanel(input, &due);
    return due;
}

/// Makes every scheduled bar source due at `now_ns`; unscheduled ones stay
/// idle. Example: `model.bar_updates.expire(now_ns);`
pub fn expire(self: *BarUpdatesState, now_ns: u64) void {
    for (&self.deadlines) |*deadline_ns| {
        if (deadline_ns.* != bar_updates.no_deadline) {
            deadline_ns.* = @min(deadline_ns.*, now_ns);
        }
    }
}

/// Starts the source of a panel that just opened; it runs immediately.
/// Example: `model.bar_updates.startPanel(.{ .index = 0, .opening = 3 }, now_ns);`
pub fn startPanel(self: *BarUpdatesState, run: PanelRun, now_ns: u64) void {
    self.panel_run = run;
    self.panel_deadline = now_ns;
    self.pending_panel_callback = false;
    self.pending_panel_command = false;
}

/// Forgets the closed panel's deadline and queued work. A command already
/// running finishes and is discarded by its opening.
pub fn stopPanel(self: *BarUpdatesState) void {
    self.panel_run = null;
    self.panel_deadline = bar_updates.no_deadline;
    self.pending_panel_callback = false;
    self.pending_panel_command = false;
}

/// Example: `model.bar_updates.scheduleClock(now_ns + remaining_ns);`
pub fn scheduleClock(self: *BarUpdatesState, deadline_ns: u64) void {
    self.clock_deadline = deadline_ns;
}

fn takePanel(self: *BarUpdatesState, input: DueInput, due: *Due) void {
    if (self.panel_deadline == bar_updates.no_deadline or self.panel_deadline > input.now_ns) {
        return;
    }

    const source = input.panel_source orelse {
        self.panel_deadline = bar_updates.no_deadline;
        return;
    };
    const interval_ns = source.interval() orelse 0;
    self.panel_deadline = if (interval_ns == 0)
        bar_updates.no_deadline
    else
        bar_updates.followingDeadline(self.panel_deadline, interval_ns, input.now_ns);
    switch (source.*) {
        .dynamic => due.panel_callback = true,
        .command => due.panel_command = true,
        else => self.panel_deadline = bar_updates.no_deadline,
    }
}

pub fn nextDeadline(self: *const BarUpdatesState) ?u64 {
    var next: u64 = bar_updates.no_deadline;
    for (self.deadlines) |deadline_ns| {
        next = @min(next, deadline_ns);
    }
    next = @min(next, self.panel_deadline);
    next = @min(next, self.clock_deadline);

    return if (next == bar_updates.no_deadline) null else next;
}

pub fn reserveCommand(self: *BarUpdatesState, generation: u64, target: CommandTarget) !CommandExecution {
    std.debug.assert(self.command_execution == null);
    if (self.next_command_execution_id == 0) {
        return error.BarCommandExecutionIdExhausted;
    }

    const execution: CommandExecution = .{
        .id = @enumFromInt(self.next_command_execution_id),
        .generation = generation,
        .target = target,
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
