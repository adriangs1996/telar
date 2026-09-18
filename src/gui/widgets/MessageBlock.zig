//! One Markdown block borrowed from the delivered conversation snapshot.
text: []const u8,
kind: enum { paragraph, heading, bullet, quote, code, spacer, rule, table } = .paragraph,
marker: []const u8 = "",
language: []const u8 = "",
fenced_closed: bool = false,
source_offset: u32 = 0,

/// Only a complete Mermaid fence is eligible for asynchronous rendering.
/// Example: `if (block.isMermaid()) requestDiagram(block);`
pub fn isMermaid(block: @This()) bool {
    return block.kind == .code and block.fenced_closed and @import("std").mem.eql(u8, block.language, "mermaid");
}
