//! One painted line of the history inspector: the command, a fact, a
//! heading or a line of captured output.
const HistoryLine = @This();

pub const Kind = enum { command, blank, fact, heading, output };
pub const Tone = enum { text, muted, red, green, teal, yellow };

kind: Kind,
label: []const u8 = "",
text: []const u8,
tone: Tone = .text,
/// Paths and identifiers keep the terminal face.
mono: bool = false,
