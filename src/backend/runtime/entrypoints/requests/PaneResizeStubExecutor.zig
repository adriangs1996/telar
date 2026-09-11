const pane_resize_commands = @import("../../application/commands/pane_resize.zig");
const PaneResizeType = @import("../../application/commands/PaneResize.zig");
const StubExecutor = @This();

result: pane_resize_commands.PaneResizeResult = .handled,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?PaneResizeType = null,

pub fn execute(stub: *StubExecutor, command: PaneResizeType) !pane_resize_commands.PaneResizeResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
