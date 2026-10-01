//! Verified destination checkout; strings belong to the calling CLI's arena.
path: [:0]const u8,
commit: []const u8,
repository: []const u8,
reused: bool,
repository_ready: bool = true,
environment: []const u8 = "not_run",
