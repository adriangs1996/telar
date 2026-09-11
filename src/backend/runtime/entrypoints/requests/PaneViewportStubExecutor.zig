const StubExecutor = @This();
const pane_viewport_commands = @import("../../application/commands/pane_viewport.zig");
result: pane_viewport_commands.SetPaneViewportResult = .changed,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?pane_viewport_commands.SetPaneViewport = null,

pub fn execute(stub: *StubExecutor, command: pane_viewport_commands.SetPaneViewport) !pane_viewport_commands.SetPaneViewportResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
