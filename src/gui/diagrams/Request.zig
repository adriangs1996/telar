//! A synchronous source borrow; the store copies it before returning.
const mermaid = @import("mermaid");
/// Identifies the content that shows the diagram, chosen by the caller, so
/// equal sources in different places keep their own slots.
owner: u64,
text: []const u8,
theme: mermaid.Theme,
scale: f32,
