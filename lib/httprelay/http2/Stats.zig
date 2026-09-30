//! What relaying one HTTP/2 direction found: whether header decoding
//! failed, and which bounds cut observation short. Traffic is relayed byte
//! for byte either way.
const Stats = @This();

decode_failed: bool = false,
/// A header block passed `max_header_block_bytes`, which ends decoding for
/// the rest of the direction.
header_block_too_large: bool = false,
/// Streams the relay could not follow because it already tracked
/// `max_tracked_streams`.
untracked_streams: u32 = 0,
