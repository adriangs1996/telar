//! One landed listing: the expanded query it answers and the borrowed result.
const Result = @import("PathCompletionResult.zig");
const Landing = @This();

query: []const u8,
result: *const Result,
