//! Wire coordinates refer to immutable file contents, never display row indices.
file: []const u8,
side: enum { before, after },
first_line: u32,
last_line: u32,
body: []const u8,
