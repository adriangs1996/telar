const Capture = @This();
const source_namespace = @import("runtime_messages_tests.zig");
calls: usize = 0,
outcome: source_namespace.Outcome = .applied,
history_failure: bool = false,
