//! Reduces captured terminal output to readable text: escape sequences and
//! control bytes are dropped, UTF-8 text, newlines and tabs are kept. It is
//! a bounded scanner, not an emulator; ghostty alone defines what a screen
//! is. History inspectors and machine-readable CLI output share it so a
//! model or a person reads the same bytes.
const std = @import("std");

const esc = 0x1b;
const bel = 0x07;

const Scanner = enum {
    ground,
    escape,
    escape_intermediate,
    csi,
    string,
    string_escape,
};

/// Copies `bytes` into `out` without CSI, OSC, DCS, APC, PM and SOS
/// sequences, lone escape sequences and C0 controls other than newline and
/// tab. A carriage return becomes nothing, so `\r\n` collapses to one line
/// break. `out` needs at most `bytes.len` bytes; the returned slice is the
/// written prefix.
///
/// ```zig
/// var storage: [64]u8 = undefined;
/// const text = plain_text.strip("\x1b[31mfail\x1b[0m\r\n", &storage);
/// // text == "fail\n"
/// ```
pub fn strip(bytes: []const u8, out: []u8) []u8 {
    var state: Scanner = .ground;
    var written: usize = 0;
    for (bytes) |byte| {
        switch (state) {
            .ground => {
                if (byte == esc) {
                    state = .escape;
                } else if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte != 0x7f)) {
                    if (written == out.len) {
                        return out[0..written];
                    }

                    out[written] = byte;
                    written += 1;
                }
            },
            .escape => state = switch (byte) {
                '[' => .csi,
                ']', 'P', 'X', '^', '_' => .string,
                0x20...0x2f => .escape_intermediate,
                esc => .escape,
                else => .ground,
            },
            .escape_intermediate => {
                if (byte == esc) {
                    state = .escape;
                } else if (byte >= 0x30) {
                    state = .ground;
                }
            },
            .csi => {
                if (byte == esc) {
                    state = .escape;
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    state = .ground;
                }
            },
            .string => state = switch (byte) {
                bel => .ground,
                esc => .string_escape,
                else => .string,
            },
            .string_escape => state = switch (byte) {
                '\\' => .ground,
                esc => .string_escape,
                else => .string,
            },
        }
    }

    return out[0..written];
}

test "strip removes sequences and controls but keeps text, newlines and tabs" {
    var storage: [128]u8 = undefined;
    try std.testing.expectEqualStrings("fail\n", strip("\x1b[31mfail\x1b[0m\r\n", &storage));
    try std.testing.expectEqualStrings("a\tb\nc", strip("\x1b]0;title\x07a\tb\x1b]7;file://h/p\x1b\\\nc", &storage));
    try std.testing.expectEqualStrings("caf\xc3\xa9 界", strip("caf\xc3\xa9\x1b(B \x1b[?25l界\x08\x00", &storage));
    try std.testing.expectEqualStrings("done", strip("\x1bP+q\x1b\\\x1b_Gm=1;AAAA\x1b\\\x1b[1;2;3H\x1b[38;2;1;2;3mdone", &storage));
    try std.testing.expectEqualStrings("ok", strip("\x1b\x1b[Aok", &storage));
}

test "strip never writes past the output and returns the written prefix" {
    var storage: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", strip("abcdef", &storage));
    try std.testing.expectEqualStrings("", strip("\x1b[2J", &storage));
    var empty: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", strip("text", &empty));
}
