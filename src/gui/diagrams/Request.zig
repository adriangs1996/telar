//! A synchronous source borrow; the store copies it before returning.
owner: @import("../widgets/MessageLayoutOwner.zig"),
block_offset: u32,
text: []const u8,
theme: @import("Theme.zig"),
scale: f32,

kind: @import("source_kind.zig").Kind = .mermaid,
