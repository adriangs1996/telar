const Capture = @This();
const detach_pane_commands = @import("../../application/commands/detach_pane.zig");
const source_namespace = @import("detach_pane.zig");
const StaleMessages = @import("StaleMessages.zig");
result: detach_pane_commands.DetachPaneResult,
command_count: usize = 0,
stale_count: usize = 0,
pane_id: source_namespace.schema.PaneId = .invalid,
failure: ?anyerror = null,

pub fn executor(capture: *Capture) detach_pane_commands.DetachPaneExecutor {
    return .{ .context = capture, .execute_fn = execute };
}

pub fn staleMessages(capture: *Capture) StaleMessages {
    return .{ .context = capture, .record = recordStale };
}

fn execute(context: *anyopaque, command: detach_pane_commands.DetachPane) !detach_pane_commands.DetachPaneResult {
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
