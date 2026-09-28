const Text = @This();

pane_id: u64,
truncated: bool,
text: []const u8,
/// Set when the pane had exited: the text is its final output.
exit_code: ?i32 = null,
