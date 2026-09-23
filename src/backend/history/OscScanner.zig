const escape_ops = @import("escape.zig");
/// Frames `ESC ]` OSC sequences and streams their payload as events.
///
/// Raw C1 introducers are deliberately not honoured: the emulator parses the
/// stream as UTF-8, where 0x9d and 0x9c are continuation bytes.
const OscScanner = @This();

state: State = .ground,

const State = enum { ground, escape, osc, osc_escape };

pub const Event = union(enum) {
    /// Byte is not part of an OSC sequence.
    none,
    /// `ESC ]` seen; a payload follows.
    start,
    /// One payload byte.
    byte: u8,
    /// The sequence terminated (BEL or ST).
    end,
};

pub fn next(self: *OscScanner, input: u8) Event {
    switch (self.state) {
        .ground => {
            if (input == escape_ops.esc) {
                self.state = .escape;
            }
            return .none;
        },
        .escape => {
            if (input == ']') {
                self.state = .osc;
                return .start;
            }
            self.state = .ground;
            return .none;
        },
        .osc => switch (input) {
            escape_ops.bel => {
                self.state = .ground;
                return .end;
            },
            escape_ops.esc => {
                self.state = .osc_escape;
                return .none;
            },
            else => return .{ .byte = input },
        },
        .osc_escape => {
            if (input == '\\') {
                self.state = .ground;
                return .end;
            }
            // An ESC that was not a terminator abandons the sequence.
            // A second ESC may still open a fresh escape.
            self.state = if (input == escape_ops.esc) .escape else .ground;
            return .none;
        },
    }
}
