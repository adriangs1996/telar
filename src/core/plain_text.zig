//! Reduces captured terminal output to readable text: escape sequences and
//! control bytes are dropped, UTF-8 text, newlines and tabs are kept. It is
//! a bounded scanner, not an emulator; ghostty alone defines what a screen
//! is. History inspectors and machine-readable CLI output share it so a
//! model or a person reads the same bytes.

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
