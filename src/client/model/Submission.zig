const Submission = @This();
const source_namespace = @import("name_prompt.zig");
target: source_namespace.Target,
/// Borrowed from the active prompt until the synchronous submit effect
/// returns.
name: []const u8,
/// True for shift+enter, which inverts the configured enter behavior of
/// list targets.
alternate: bool = false,
