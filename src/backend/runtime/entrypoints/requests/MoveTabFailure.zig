const Failure = @This();
const source_namespace = @import("move_tab.zig");
code: source_namespace.schema.FailureCode,
message: []const u8,
