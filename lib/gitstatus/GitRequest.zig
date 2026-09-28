const std = @import("std");
/// One read-only Git command `untrusted_git.run` runs in a checkout.
const GitRequest = @This();

/// The runtime's environment; Git gets it with its hardening added.
environ: std.process.Environ,
/// The checkout Git runs in, passed as `-C`.
path: []const u8,
/// The Git command and its arguments, without `git`.
arguments: []const []const u8,
timeout: std.Io.Timeout,
stdout_limit: usize,
