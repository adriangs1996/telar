const TabDetachmentPlan = @This();
const source_namespace = @import("types.zig");
location: source_namespace.schema.TabLocation,
panes: [source_namespace.multiplexer.max_panes]Pane = undefined,
len: u8 = 0,
owns_paste: bool = false,
owns_reported_focus: bool = false,
paste_marker_required: bool = false,
focus_out_required: bool = false,

pub const Pane = struct {
    pane_id: source_namespace.schema.PaneId,
    attached: bool,
};

/// Returns the exact panes captured for one synchronous tab detachment.
///
/// ```zig
/// for (plan.slice()) |pane| detach(pane.pane_id);
/// ```
pub fn slice(plan: *const TabDetachmentPlan) []const Pane {
    return plan.panes[0..plan.len];
}
