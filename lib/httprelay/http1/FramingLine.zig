//! Which line of chunked framing passed its bound.
pub const FramingLine = enum {
    /// A chunk-size line: `max_chunk_line_bytes`.
    chunk_size,
    /// A trailer field line: `max_trailer_line_bytes`.
    trailer,
};
