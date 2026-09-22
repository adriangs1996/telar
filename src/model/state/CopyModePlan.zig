const core = @import("telar-core");
const model_data = @import("../model.zig");
const CopyModePlan = @This();

expected_revision: u64,
previous: model_data.State,
next: ?model_data.State,
selection: ?core.CopySelection = null,
viewport: ?core.SetPaneViewport = null,
/// Open the search input in this direction after the commit.
search: ?model_data.CopyModeDirection = null,
/// Open this immutable target without committing copy-mode state.
open_link: ?model_data.LinkTarget = null,
