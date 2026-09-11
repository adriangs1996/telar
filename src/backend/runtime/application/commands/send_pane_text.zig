//! Application command for text sent to one exact pane generation by a
//! control client that holds no attachment.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const pane_input_commands = @import("pane_input.zig");

pub const schema = core.schema;
pub const PaneKey = pane_mod.PaneKey;
pub const PaneStore = pane_mod.PaneStore;
pub const Tracker = agent_mod.Tracker;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const enter = "\r";
pub const prompt_overhead = paste_start.len + paste_end.len + enter.len;

pub const SendPaneText = @import("SendPaneText.zig");

pub const SendPaneTextResult = enum {
    handled,
    pane_not_found,
    pane_exited,
    agent_blocked,
};

pub const SendPaneTextHandler = @import("SendPaneTextHandler.zig");

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
