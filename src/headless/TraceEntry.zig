//! One moment the headless client's trace keeps.
const TraceEntry = @This();

/// Bytes of an entry's label.
pub const label_bytes = 32;

pub const Kind = enum(u8) {
    /// A pane frame the client presented and acknowledged.
    frame,
    /// An input line took effect.
    input,
    /// A `mark` line.
    mark,
    /// A host request the client recorded instead of performing.
    effect,
};

kind: Kind,
t_ns: u64,
pane: u64 = 0,
frame: u64 = 0,
label: [label_bytes]u8 = undefined,
label_len: u8 = 0,
