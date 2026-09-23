//! A bounded cache slot; source identity never relies on a hash alone.
const view = @import("view.zig");
const source_kind = @import("source_kind.zig");
const MessageLayoutOwner = @import("../widgets/MessageLayoutOwner.zig");
const Theme = @import("Theme.zig");
const Image = @import("Image.zig");
source: ?[]u8 = null,
owner: MessageLayoutOwner = undefined,
block_offset: u32 = 0,
theme: Theme = undefined,
scale: f32 = 1,
id: u64 = 0,
frame: u64 = 0,
status: enum { pending, running, ready, failed } = .pending,
failure: view.Failure = .invalid,
image: ?Image = null,

kind: source_kind.Kind = .mermaid,
