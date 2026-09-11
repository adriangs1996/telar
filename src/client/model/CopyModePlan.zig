const StateType = @import("../input/State.zig");
const CopySelectionType = @import("telar-core").CopySelection;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const copy_mode_module = @import("../input/copy_mode.zig");
const TargetType = @import("../links/LinkTarget.zig");
const CopyModePlan = @This();

expected_revision: u64,
previous: StateType,
next: ?StateType,
selection: ?CopySelectionType = null,
viewport: ?SetPaneViewportType = null,
/// Open the search input in this direction after the commit.
search: ?copy_mode_module.Direction = null,
/// Open this immutable target without committing copy-mode state.
open_link: ?TargetType = null,
