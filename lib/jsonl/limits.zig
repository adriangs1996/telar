//! Bounds of one JSONL record.

/// The longest line held whole; a longer one takes the output-truncation
/// path when the stream has an `OutputFrame`, and fails otherwise.
pub const max_line_bytes = 256 * 1024;
