//! Application use case for delivering semantic user input to one pane.

const input_capability = @import("../../input/input_namespace.zig");

const KeyType = @import("../../input/Key.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const std = @import("std");
const chord = @import("../../input/chord.zig");

pub const max_bytes = input_capability.max_encoded_bytes;
/// Keys one synthetic sequence may carry; each key encodes to at most 32 bytes.
pub const max_keys: usize = input_capability.max_encoded_bytes / 32;

pub const Source = enum {
    host,
    paste,
    mouse,
};

pub const Payload = union(enum) {
    bytes: []const u8,
    key: KeyType,
};

pub const Command = @import("PaneInputCommand.zig");

pub const PasteMarker = enum {
    start,
    finish,
};

pub const PasteMarkerCommand = @import("PasteMarkerCommand.zig");

pub const PaneInputEffect = @import("PaneInputEffect.zig");

pub const Delivery = @import("PaneInputDelivery.zig");

/// Rejects terminal controls and unframed multiline text before history can send input.
/// Example: `try validateHistoryText(command, modes.bracketed_paste);`.
pub fn validateHistoryText(text: []const u8, bracketed_paste: bool) !void {
    if (text.len == 0 or text.len > max_history_command_bytes_module) {
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

pub const EffectEvent = enum {
    viewport,
    input,
};
