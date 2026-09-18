//! One owned request. There is at most one active helper process per GUI.
const Theme = @import("Theme.zig");
const Job = @This();

pub const max_source_bytes = 48 * 1024;

id: u64,
slot: u8,
source: [max_source_bytes]u8 = undefined,
len: u32,
theme: Theme,
scale: f32,
kind: @import("source_kind.zig").Kind = .mermaid,

/// Example: `try writer.writeAll(job.text());`
pub fn text(job: *const Job) []const u8 {
    return job.source[0..job.len];
}
