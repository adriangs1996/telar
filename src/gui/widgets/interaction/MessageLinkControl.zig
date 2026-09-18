//! A visible Markdown destination identified without retaining snapshot bytes.
owner: @import("../MessageLayoutOwner.zig"),
destination_offset: u32,
destination_len: u32,
fragment_offset: u32 = 0,
