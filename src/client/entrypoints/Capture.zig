const runtime_messages_tests = @import("runtime_messages_tests.zig");
const Capture = @This();

calls: usize = 0,
outcome: runtime_messages_tests.Outcome = .applied,
history_failure: bool = false,
