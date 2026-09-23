//! Owned source coordinates for one rendered message or expanded activity.
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");

owner: MessageLayoutOwner,
order: u16,
body_len: u32,
detail_offset: u32,
detail_len: u32,
markdown: bool,
code: bool,
