//! A bounded cache slot; source identity never relies on a hash alone.
const view = @import("view.zig");
const source_kind = @import("source_kind.zig");
source: ?[]u8 = null,
owner: @import("../widgets/MessageLayoutOwner.zig") = undefined,
block_offset: u32 = 0,
theme: @import("Theme.zig") = undefined,
scale: f32 = 1,
id: u64 = 0,
frame: u64 = 0,
status: enum { pending, running, ready, failed } = .pending,
failure: view.Failure = .invalid,
image: ?@import("Image.zig") = null,

kind: source_kind.Kind = .mermaid,
