const Failure = @This();
const source_namespace = @import("open_pane.zig");
code: source_namespace.schema.FailureCode,
message: []const u8,
