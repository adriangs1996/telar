const Failure = @This();
const source_namespace = @import("rename_workspace.zig");
code: source_namespace.schema.FailureCode,
message: []const u8,
