const StubExecutor = @This();
const pane_input_commands = @import("../../application/commands/pane_input.zig");
result: pane_input_commands.PaneInputResult = .handled,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?pane_input_commands.PaneInput = null,

pub fn execute(stub: *StubExecutor, command: pane_input_commands.PaneInput) !pane_input_commands.PaneInputResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
