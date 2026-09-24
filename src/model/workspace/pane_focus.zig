//! Focusing a pane and keeping the focus the runtime was told about in step with it.

const PaneFocusReportTransition = @import("../state/PaneFocusReportTransition.zig");
const std = @import("std");
const ReportedPaneFocus = @import("../state/ReportedPaneFocus.zig");
const tab_layout = @import("tab_layout.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Commits the active focused pane as the protocol-reporting target. The
/// returned transition names the ordered focus messages, if any.
///
/// ```zig
/// const transition = pane_focus.syncReported(model) orelse return;
/// ```
pub fn syncReported(model: *ClientModel) ?PaneFocusReportTransition {
    const current: ?ReportedPaneFocus = current: {
        const slot = model.tabs.activeSlot() orelse break :current null;
        const pane = tab_layout.focusedPane(model, slot) orelse break :current null;
        const pane_id = pane.id;

        break :current .{
            .pane_id = pane_id,
            .focus_events = pane.attached and pane.input_modes.focus_events,
        };
    };

    return commitReported(model, current);
}

/// Clears an intentional focus owner and returns any required focus-out.
///
/// ```zig
/// const transition = pane_focus.clearReported(model) orelse return;
/// ```
pub fn clearReported(model: *ClientModel) ?PaneFocusReportTransition {
    return commitReported(model, null);
}

/// Forgets protocol focus after canonical state made the old owner stale.
///
/// ```zig
/// _ = pane_focus.forgetReported(model);
/// ```
pub fn forgetReported(model: *ClientModel) bool {
    if (model.reported_pane_focus == null) {
        return false;
    }

    model.reported_pane_focus = null;
    return true;
}

/// Releases protocol focus only when its pane is being retired.
///
/// ```zig
/// _ = pane_focus.releaseReported(model, pane_id);
/// ```
pub fn releaseReported(model: *ClientModel, pane_id: core.PaneId) bool {
    const reported = model.reported_pane_focus orelse return false;
    if (reported.pane_id != pane_id) {
        return false;
    }

    model.reported_pane_focus = null;
    return true;
}

/// Changes focus inside the active tab and reports the committed identity
/// and pane revision. Repeated, missing and directionless targets leave
/// every version intact.
///
/// ```zig
/// const focus = pane_focus.focusPane(model, .{ .target = .{ .direction = .left }, .area = area }) orelse return;
/// ```
pub fn focusPane(model: *ClientModel, request: model_data.PaneFocusRequest) ?model_data.PaneFocus {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const previous = layout.focused() orelse return null;
    const focused = switch (request.target) {
        .pane_id => |pane_id| focused: {
            if (pane_id == previous or !layout.focusPane(pane_id)) {
                return null;
            }

            break :focused pane_id;
        },
        .direction => |direction| layout.focusDirection(direction, request.area) orelse return null,
    };
    std.debug.assert(focused != previous);

    model.panes_revision +%= 1;

    return .{
        .location = model.tabs.location[slot],
        .previous = previous,
        .focused = focused,
        .geometry_changed = layout.isFullscreen(),
        .panes_revision = model.panes_revision,
    };
}

fn commitReported(model: *ClientModel, current: ?ReportedPaneFocus) ?PaneFocusReportTransition {
    const previous = model.reported_pane_focus;
    if (std.meta.eql(previous, current)) {
        return null;
    }

    var transition: PaneFocusReportTransition = .{
        .previous = previous,
        .current = current,
    };
    if (previous) |reported| {
        const moved = if (current) |focus|
            focus.pane_id != reported.pane_id
        else
            true;
        if (moved and reported.focus_events) {
            if (model.panes.find(reported.pane_id)) |pane| {
                if (pane.attached) {
                    transition.focus_out = reported.pane_id;
                }
            }
        }
    }

    if (current) |reported| {
        const entered = if (previous) |focus|
            focus.pane_id != reported.pane_id or !focus.focus_events
        else
            true;
        if (entered and reported.focus_events) {
            transition.focus_in = reported.pane_id;
        }
    }

    model.reported_pane_focus = current;
    return transition;
}
