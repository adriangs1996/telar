//! Application command for text sent to one exact pane generation by a
//! control client that holds no attachment.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const pane_input_commands = @import("pane_input.zig");

const schema = core.schema;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const Tracker = agent_mod.Tracker;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const enter = "\r";
pub const prompt_overhead = paste_start.len + paste_end.len + enter.len;

pub const SendPaneText = struct {
    pane: PaneKey,
    mode: schema.PaneTextMode,
    text: []const u8,
};

pub const SendPaneTextResult = enum {
    handled,
    pane_not_found,
    pane_exited,
    agent_blocked,
};

pub const SendPaneTextHandler = struct {
    panes: *PaneStore,
    agents: *const Tracker,
    input: pane_input_commands.Forwarder,

    /// Resolves the exact pane generation and forwards the text. A prompt is
    /// refused while the projected agent is blocked, wrapped in bracketed paste
    /// when the child enabled that mode, and followed by Enter.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane = key, .mode = .prompt, .text = "run the tests" });
    /// ```
    pub fn execute(handler: *SendPaneTextHandler, command: SendPaneText) !SendPaneTextResult {
        const pane = handler.panes.resolveControl(command.pane) orelse return .pane_not_found;

        if (pane.exit != null) {
            return .pane_exited;
        }

        var storage: [schema.max_pane_text_input_bytes + prompt_overhead]u8 = undefined;
        const bytes = switch (command.mode) {
            .raw => command.text,
            .prompt => prompt: {
                if (handler.agents.projectedStatus(command.pane) == .blocked) {
                    return .agent_blocked;
                }

                break :prompt promptBytes(&storage, command.text, pane.terminal.modes.get(.bracketed_paste));
            },
        };

        try handler.input.forward(pane, bytes);
        if (command.mode == .prompt or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
            pane.noteInjectedSubmission();
        }

        return .handled;
    }
};

/// Frames one prompt the way a terminal paste followed by Enter would arrive.
///
/// ```zig
/// const bytes = promptBytes(&storage, "hello", true);
/// ```
pub fn promptBytes(storage: *[schema.max_pane_text_input_bytes + prompt_overhead]u8, text: []const u8, bracketed: bool) []const u8 {
    std.debug.assert(text.len <= schema.max_pane_text_input_bytes);
    var len: usize = 0;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_start.len], paste_start);
        len += paste_start.len;
    }

    @memcpy(storage[len .. len + text.len], text);
    len += text.len;

    if (bracketed) {
        @memcpy(storage[len .. len + paste_end.len], paste_end);
        len += paste_end.len;
    }

    @memcpy(storage[len .. len + enter.len], enter);
    len += enter.len;
    return storage[0..len];
}

test "promptBytes frames a paste only when the child asked for it" {
    var storage: [schema.max_pane_text_input_bytes + prompt_overhead]u8 = undefined;

    try std.testing.expectEqualStrings("hello\r", promptBytes(&storage, "hello", false));
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~\r", promptBytes(&storage, "hello", true));
}
