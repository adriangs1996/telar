//! One landed listing: the expanded query it answers and the borrowed result.
const Result = @import("PathCompletionResult.zig");

query: []const u8,
result: *const Result,
