//! Inline Markdown over borrowed text: strong, emphasis, code and links as
//! styled spans that keep their link destination and source offset, bare
//! URLs recognized like a terminal recognizes them, and bounded decoding of
//! a link destination for display. Unsupported syntax stays literal, and
//! lookahead is budgeted linearly in the text.

pub const Destination = @import("Destination.zig");
pub const Span = @import("Span.zig");
pub const Spans = @import("Spans.zig");

test {
    _ = @import("Destination.zig");
    _ = @import("Scope.zig");
    _ = @import("Span.zig");
    _ = @import("Spans.zig");
    _ = @import("spans_tests.zig");
}
