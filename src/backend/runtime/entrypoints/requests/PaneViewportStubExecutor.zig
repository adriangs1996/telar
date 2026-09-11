const pane_viewport_commands = @import("../../application/commands/pane_viewport.zig");
const SetPaneViewportType = @import("../../application/commands/SetPaneViewport.zig");
const StubExecutor = @This();

result: pane_viewport_commands.SetPaneViewportResult = .changed,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?SetPaneViewportType = null,

pub fn execute(stub: *StubExecutor, command: SetPaneViewportType) !pane_viewport_commands.SetPaneViewportResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
