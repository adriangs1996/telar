const name_prompt = @import("name_prompt.zig");
const Submission = @This();

target: name_prompt.Target,
/// Borrowed from the active prompt until the synchronous submit effect
/// returns.
name: []const u8,
/// True for shift+enter, which inverts the configured enter behavior of
/// list targets.
alternate: bool = false,
/// Borrowed working directory of the new-context form; empty inherits the
/// focused pane's directory.
directory: []const u8 = "",
/// The user confirmed creating a directory that did not exist.
create_directory: bool = false,
