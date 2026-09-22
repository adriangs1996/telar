//! Application command for text sent to one exact pane generation by a
//! control client that holds no attachment.

const core = @import("telar-core");
const std = @import("std");

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const enter = "\r";
pub const prompt_overhead = paste_start.len + paste_end.len + enter.len;

pub const SendPaneTextResult = enum {
    handled,
    pane_not_found,
    pane_exited,
    agent_blocked,
    not_terminal,
};

/// Frames one prompt the way a terminal paste followed by Enter would arrive.
///
/// ```zig
/// const bytes = promptBytes(&storage, "hello", true);
/// ```
pub fn promptBytes(storage: *[core.max_pane_text_input_bytes + prompt_overhead]u8, text: []const u8, bracketed: bool) []const u8 {
    std.debug.assert(text.len <= core.max_pane_text_input_bytes);
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
    var storage: [core.max_pane_text_input_bytes + prompt_overhead]u8 = undefined;

    try std.testing.expectEqualStrings("hello\r", promptBytes(&storage, "hello", false));
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~\r", promptBytes(&storage, "hello", true));
}
