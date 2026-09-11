const CopyModePlan = @This();
const source_namespace = @import("types.zig");
const link_capability = @import("../links/root.zig");
expected_revision: u64,
previous: source_namespace.copy_mode.State,
next: ?source_namespace.copy_mode.State,
selection: ?source_namespace.schema.CopySelection = null,
viewport: ?source_namespace.schema.SetPaneViewport = null,
/// Open the search input in this direction after the commit.
search: ?source_namespace.copy_mode.Direction = null,
/// Open this immutable target without committing copy-mode state.
open_link: ?link_capability.Target = null,
