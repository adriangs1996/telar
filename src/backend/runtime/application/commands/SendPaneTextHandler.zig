const SendPaneTextHandler = @This();
const source_namespace = @import("send_pane_text.zig");
const pane_input_commands = @import("pane_input.zig");
const SendPaneText = @import("SendPaneText.zig");
const std = @import("std");
panes: *source_namespace.PaneStore,
agents: *const source_namespace.Tracker,
input: pane_input_commands.Forwarder,

/// Resolves the exact pane generation and forwards the text. A prompt is
/// refused while the projected agent is blocked, wrapped in bracketed paste
/// when the child enabled that mode, and followed by Enter.
///
/// ```zig
/// const result = try handler.execute(.{ .pane = key, .mode = .prompt, .text = "run the tests" });
/// ```
pub fn execute(handler: *SendPaneTextHandler, command: SendPaneText) !source_namespace.SendPaneTextResult {
    const pane = handler.panes.resolveControl(command.pane) orelse return .pane_not_found;

    if (pane.exit != null) {
        return .pane_exited;
    }

    var storage: [source_namespace.schema.max_pane_text_input_bytes + source_namespace.prompt_overhead]u8 = undefined;
    const bytes = switch (command.mode) {
        .raw => command.text,
        .prompt => prompt: {
            if (handler.agents.projectedStatus(command.pane) == .blocked) {
                return .agent_blocked;
            }

            break :prompt source_namespace.promptBytes(&storage, command.text, pane.terminal.modes.get(.bracketed_paste));
        },
    };

    try handler.input.forward(pane, bytes);
    if (command.mode == .prompt or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    return .handled;
}
