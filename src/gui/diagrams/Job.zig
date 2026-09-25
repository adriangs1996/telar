//! One owned request. There is at most one active helper process per GUI.
const mermaid = @import("mermaid");
const Job = @This();

pub const max_source_bytes = 48 * 1024;

id: u64,
slot: u8,
source: [max_source_bytes]u8 = undefined,
len: u32,
theme: mermaid.Theme,
scale: f32,

/// Example: `try writer.writeAll(job.text());`
pub fn text(self: *const Job) []const u8 {
    return self.source[0..self.len];
}

/// Borrows the owned source for one render.
/// Example: `const image = try mermaid.render(io, allocator, job.request(), helpers);`
pub fn request(self: *const Job) mermaid.Request {
    return .{ .source = self.text(), .theme = self.theme, .scale = self.scale };
}
