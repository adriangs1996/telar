//! Bounds-checked little-endian encoding into caller-owned buffers and
//! decoding from borrowed bytes. Neither side allocates; every read and
//! write reports truncation or a short buffer instead of trapping.

pub const Decoder = @import("Decoder.zig");
pub const Encoder = @import("Encoder.zig");

test {
    _ = @import("Decoder.zig");
    _ = @import("Encoder.zig");
    _ = @import("codec_tests.zig");
}
