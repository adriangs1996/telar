//! A visible Markdown destination identified without retaining snapshot bytes.
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");

owner: MessageLayoutOwner,
destination_offset: u32,
destination_len: u32,
fragment_offset: u32 = 0,
