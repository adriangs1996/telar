//! A bounded cache slot; source identity never relies on a hash alone.
const mermaid = @import("mermaid");
const view = @import("view.zig");
source: ?[]u8 = null,
owner: u64 = 0,
theme: mermaid.Theme = undefined,
scale: f32 = 1,
id: u64 = 0,
frame: u64 = 0,
status: enum { pending, running, ready, failed } = .pending,
failure: view.Failure = .invalid,
image: ?mermaid.Image = null,
