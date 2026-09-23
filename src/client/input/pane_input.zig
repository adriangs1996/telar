//! Application use case for delivering semantic user input to one pane.

const core = @import("telar-core");

const std = @import("std");

/// Rejects terminal controls and unframed multiline text before history can send input.
/// Example: `try validateHistoryText(command, modes.bracketed_paste);`.
pub fn validateHistoryText(text: []const u8, bracketed_paste: bool) !void {
    if (text.len == 0 or text.len > core.max_history_command_bytes) {
        return error.InvalidInputLength;
    }

    const view = std.unicode.Utf8View.init(text) catch return error.UnsafeHistoryText;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n' or codepoint == '\t') {
            if (!bracketed_paste) {
                return error.UnframedHistoryText;
            }

            continue;
        }

        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            return error.UnsafeHistoryText;
        }
    }
}

test "history paste cannot smuggle terminal keys or escape its bracketed boundary" {
    try validateHistoryText("echo café", false);
    try validateHistoryText("echo first\necho second", true);
    try std.testing.expectError(error.UnframedHistoryText, validateHistoryText("echo first\necho second", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x1b[201~\r", true));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x03", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo \xc2\x9b", true));
}
