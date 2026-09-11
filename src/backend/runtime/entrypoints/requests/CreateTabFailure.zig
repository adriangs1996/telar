const Failure = @This();
const source_namespace = @import("create_tab.zig");
code: source_namespace.schema.FailureCode,
message: []const u8,
