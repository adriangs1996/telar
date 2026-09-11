const PaneStoreType = @import("../../../pane/PaneStore.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const ForwarderType = @import("Forwarder.zig");
const SendPaneText = @import("SendPaneText.zig");
const send_pane_text = @import("send_pane_text.zig");
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const std = @import("std");
const SendPaneTextHandler = @This();

panes: *PaneStoreType,
agents: *const TrackerType,
input: ForwarderType,

/// Resolves the exact pane generation and forwards the text. A prompt is
/// refused while the projected agent is blocked, wrapped in bracketed paste
/// when the child enabled that mode, and followed by Enter.
///
/// ```zig
/// const result = try handler.execute(.{ .pane = key, .mode = .prompt, .text = "run the tests" });
/// ```
pub fn execute(handler: *SendPaneTextHandler, command: SendPaneText) !send_pane_text.SendPaneTextResult {
    const pane = handler.panes.resolveControl(command.pane) orelse return .pane_not_found;

    if (pane.exit != null) {
        return .pane_exited;
    }

    var storage: [max_pane_text_input_bytes_module + send_pane_text.prompt_overhead]u8 = undefined;
    const bytes = switch (command.mode) {
        .raw => command.text,
        .prompt => prompt: {
            if (handler.agents.projectedStatus(command.pane) == .blocked) {
                return .agent_blocked;
            }

            break :prompt send_pane_text.promptBytes(&storage, command.text, pane.terminal.modes.get(.bracketed_paste));
        },
    };

    try handler.input.forward(pane, bytes);
    if (command.mode == .prompt or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    return .handled;
}
