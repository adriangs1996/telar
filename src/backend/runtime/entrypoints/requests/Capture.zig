const detach_pane_commands = @import("../../application/commands/detach_pane.zig");
const PaneIdType = @import("telar-core").PaneId;
const DetachPaneExecutorType = @import("../../application/commands/DetachPaneExecutor.zig");
const StaleMessages = @import("StaleMessages.zig");
const DetachPaneType = @import("../../application/commands/DetachPane.zig");
const Capture = @This();

result: detach_pane_commands.DetachPaneResult,
command_count: usize = 0,
stale_count: usize = 0,
pane_id: PaneIdType = .invalid,
failure: ?anyerror = null,

pub fn executor(capture: *Capture) DetachPaneExecutorType {
    return .{ .context = capture, .execute_fn = execute };
}

pub fn staleMessages(capture: *Capture) StaleMessages {
    return .{ .context = capture, .record = recordStale };
}

fn execute(context: *anyopaque, command: DetachPaneType) !detach_pane_commands.DetachPaneResult {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.command_count += 1;
    capture.pane_id = command.pane_id;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.result;
}

fn recordStale(context: *anyopaque) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.stale_count += 1;
}
