const StubExecutor = @This();
const send_pane_text_commands = @import("../../application/commands/send_pane_text.zig");
result: send_pane_text_commands.SendPaneTextResult = .handled,
command: ?send_pane_text_commands.SendPaneText = null,

pub fn execute(stub: *StubExecutor, command: send_pane_text_commands.SendPaneText) !send_pane_text_commands.SendPaneTextResult {
    stub.command = command;
    return stub.result;
}
