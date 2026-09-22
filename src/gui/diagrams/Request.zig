//! A synchronous source borrow; the store copies it before returning.
const source_kind = @import("source_kind.zig");
owner: @import("../widgets/MessageLayoutOwner.zig"),
block_offset: u32,
text: []const u8,
theme: @import("Theme.zig"),
scale: f32,

kind: source_kind.Kind = .mermaid,
