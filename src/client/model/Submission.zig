const name_prompt = @import("name_prompt.zig");
const Submission = @This();

target: name_prompt.Target,
/// Borrowed from the active prompt until the synchronous submit effect
/// returns.
name: []const u8,
/// True for shift+enter, which inverts the configured enter behavior of
/// list targets.
alternate: bool = false,
