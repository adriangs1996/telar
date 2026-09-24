//! Incremental, bounded decoding of Server-Sent Events: events cross any
//! read boundary, oversized fields are truncated, and nothing allocates.

pub const Decoder = @import("Decoder.zig");
pub const SseEvent = @import("SseEvent.zig");
pub const sse = @import("sse.zig");

test {
    _ = @import("Decoder.zig");
    _ = @import("SseCapture.zig");
    _ = @import("SseEvent.zig");
    _ = @import("sse.zig");
}
