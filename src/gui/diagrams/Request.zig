//! A synchronous source borrow; the store copies it before returning.
const source_kind = @import("source_kind.zig");
const MessageLayoutOwner = @import("../widgets/MessageLayoutOwner.zig");
const Theme = @import("Theme.zig");
owner: MessageLayoutOwner,
block_offset: u32,
text: []const u8,
theme: Theme,
scale: f32,

kind: source_kind.Kind = .mermaid,
