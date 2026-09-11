/// Search matches are small and computed at request time, so the reply owns
/// its copy.
const PendingPaneMatches = @This();
const source_namespace = @import("response_queue.zig");
const search_commands = @import("../application/commands/search_pane.zig");
request_id: source_namespace.schema.RequestId,
pane_id: source_namespace.schema.PaneId,
matches: search_commands.Matches,
