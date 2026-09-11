const StubExecutor = @This();
const pane_resize_commands = @import("../../application/commands/pane_resize.zig");
result: pane_resize_commands.PaneResizeResult = .handled,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?pane_resize_commands.PaneResize = null,

pub fn execute(stub: *StubExecutor, command: pane_resize_commands.PaneResize) !pane_resize_commands.PaneResizeResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
