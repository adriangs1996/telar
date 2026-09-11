const pane_input_commands = @import("../../application/commands/pane_input.zig");
const PaneInputType = @import("../../application/commands/PaneInput.zig");
const StubExecutor = @This();

result: pane_input_commands.PaneInputResult = .handled,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?PaneInputType = null,

pub fn execute(stub: *StubExecutor, command: PaneInputType) !pane_input_commands.PaneInputResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
