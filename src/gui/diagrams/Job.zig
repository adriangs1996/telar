//! One owned request. There is at most one active helper process per GUI.
const source_kind = @import("source_kind.zig");
const Theme = @import("Theme.zig");
const Job = @This();

pub const max_source_bytes = 48 * 1024;

id: u64,
slot: u8,
source: [max_source_bytes]u8 = undefined,
len: u32,
theme: Theme,
scale: f32,
kind: source_kind.Kind = .mermaid,

/// Example: `try writer.writeAll(job.text());`
pub fn text(self: *const Job) []const u8 {
    return self.source[0..self.len];
}
