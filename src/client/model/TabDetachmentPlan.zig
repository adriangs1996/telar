const PaneType = @import("Pane.zig");
const TabLocationType = @import("telar-core").TabLocation;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const TabDetachmentPlan = @This();

location: TabLocationType,
panes: [max_panes_per_tab]PaneType = undefined,
len: u8 = 0,
owns_paste: bool = false,
owns_reported_focus: bool = false,
paste_marker_required: bool = false,
focus_out_required: bool = false,

pub const Pane = @import("Pane.zig");

/// Returns the exact panes captured for one synchronous tab detachment.
///
/// ```zig
/// for (plan.slice()) |pane| detach(pane.pane_id);
/// ```
pub fn slice(plan: *const TabDetachmentPlan) []const PaneType {
    return plan.panes[0..plan.len];
}
