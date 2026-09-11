/// Frames `ESC ]` OSC sequences and streams their payload as events.
///
/// Raw C1 introducers are deliberately not honoured: the emulator parses the
/// stream as UTF-8, where 0x9d and 0x9c are continuation bytes.
const OscScanner = @This();
const source_namespace = @import("escape.zig");
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

pub fn next(scanner: *OscScanner, input: u8) Event {
    switch (scanner.state) {
        .ground => {
            if (input == source_namespace.esc) {
                scanner.state = .escape;
            }
            return .none;
        },
        .escape => {
            if (input == ']') {
                scanner.state = .osc;
                return .start;
            }
            scanner.state = .ground;
            return .none;
        },
        .osc => switch (input) {
            source_namespace.bel => {
                scanner.state = .ground;
                return .end;
            },
            source_namespace.esc => {
                scanner.state = .osc_escape;
                return .none;
            },
            else => return .{ .byte = input },
        },
        .osc_escape => {
            if (input == '\\') {
                scanner.state = .ground;
                return .end;
            }
            // An ESC that was not a terminator abandons the sequence.
            // A second ESC may still open a fresh escape.
            scanner.state = if (input == source_namespace.esc) .escape else .ground;
            return .none;
        },
    }
}
