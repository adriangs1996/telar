const send_pane_text_commands = @import("../../application/commands/send_pane_text.zig");
const SendPaneTextType = @import("../../application/commands/SendPaneText.zig");
const StubExecutor = @This();

result: send_pane_text_commands.SendPaneTextResult = .handled,
command: ?SendPaneTextType = null,

pub fn execute(stub: *StubExecutor, command: SendPaneTextType) !send_pane_text_commands.SendPaneTextResult {
    stub.command = command;
    return stub.result;
}
