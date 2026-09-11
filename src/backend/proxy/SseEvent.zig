/// One complete SSE event.
///
/// `name` and `data` borrow storage from the decoder. They remain valid only
/// while the callback passed to `Decoder.feed` is running. A consumer that
/// needs either value afterwards must copy it.
const Event = @This();

/// Explicit `event` value, or `"message"` when no value was provided.
name: []const u8,

/// Values from all `data` fields, joined with one LF between fields.
data: []const u8,

/// Whether a line, event name, or event data exceeded its fixed bound.
truncated: bool,
