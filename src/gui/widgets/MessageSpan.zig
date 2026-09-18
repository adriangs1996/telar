//! Synchronously borrowed inline text, style and optional Markdown destination.
text: []const u8,
kind: enum { plain, strong, emphasis, code } = .plain,
destination: ?[]const u8 = null,
link_offset: u32 = 0,
