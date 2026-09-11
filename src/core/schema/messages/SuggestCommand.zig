/// Asks the runtime's engine for one shell command that fulfils `text` in
/// the context of `pane_id` (its cwd and visible screen).
const SuggestCommand = @This();
const source_namespace = @import("suggestion.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
text: []const u8,
