//! The client-owned arrangement of one tab's panes: geometry, focus and
//! pointer targets. `slot` is the tab's position in `model.tabs`.
const core = @import("telar-core");
const std = @import("std");
const Model = @import("../state/Model.zig");
const Pane = @import("../panes/Pane.zig");
const Spec = @import("../panes/Spec.zig");
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const LayoutView = @import("LayoutView.zig");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const PaneMousePlan = @import("PaneMousePlan.zig");
const ProspectiveSplit = @import("ProspectiveSplit.zig");
const SplitTarget = @import("SplitTarget.zig");
const PaneSet = @import("PaneSet.zig");
const Mouse = @import("../input/Mouse.zig");
const multiplexer = @import("multiplexer.zig");

/// Geometry of one tab for `area`, rebuilt only when the tab, its layout
/// revision or the area changed since the previous query.
/// Example: `const snapshot = tab_layout.snapshot(model, slot, area);`
pub fn snapshot(model: *Model, slot: usize, area: core.Rect) *const LayoutSnapshot {
    core.profiling.add(.layout_query, 1);
    const tab_id = model.tabs.location[slot].tab_id;
    const layout = &model.tabs.layout[slot];
    if (model.layout_snapshot_tab != tab_id or
        model.layout_snapshot.revision != layout.currentRevision() or
        !std.meta.eql(model.layout_snapshot.area, area))
    {
        core.profiling.add(.layout_rebuild, 1);
        layout.snapshot(area, &model.layout_snapshot);
        model.layout_snapshot_tab = tab_id;
    }

    return &model.layout_snapshot;
}

/// Example: `const view = tab_layout.view(model, slot, pane_id, area) orelse return;`
pub fn view(model: *Model, slot: usize, pane_id: core.PaneId, area: core.Rect) ?LayoutView {
    return snapshot(model, slot, area).find(pane_id);
}

/// The terminal size a pane gets inside `area`, in cells and host pixels.
/// Example: `const size = tab_layout.contentSize(model, slot, pane_id, area) orelse return;`
pub fn contentSize(model: *Model, slot: usize, pane_id: core.PaneId, area: core.Rect) ?core.TerminalSize {
    const pane_view = view(model, slot, pane_id, area) orelse return null;
    var size = multiplexer.rectSize(pane_view.content) orelse return null;
    const host_size = model.host.host_size;
    size.cell_width_px = host_size.cell_width_px;
    size.cell_height_px = host_size.cell_height_px;
    return size;
}

/// Previews splitting a pane against the tab's current membership.
/// Example: `const split = tab_layout.prospectiveSplit(model, slot, target, area);`
pub fn prospectiveSplit(model: *Model, slot: usize, target: SplitTarget, area: core.Rect) ?ProspectiveSplit {
    const pane_count = model.panes.countIn(model.tabs.location[slot].tab_id);
    return snapshot(model, slot, area).prospectiveSplit(target, pane_count);
}

/// Example: `const pane = tab_layout.focusedPane(model, slot) orelse return;`
pub fn focusedPane(model: *Model, slot: usize) ?*Pane {
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    return model.panes.findIn(model.tabs.location[slot].tab_id, pane_id);
}

/// Example: `const pane = tab_layout.focusedPaneConst(model, slot) orelse return;`
pub fn focusedPaneConst(model: *const Model, slot: usize) ?*const Pane {
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    return model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id);
}

/// Resolves one pointer event to a visible pane. Wheel events target the
/// pane under the pointer; every other event targets the focused pane.
/// Example: `const plan = tab_layout.planPaneMouse(model, slot, event, area) orelse return;`
pub fn planPaneMouse(model: *Model, slot: usize, event: Mouse, area: core.Rect) ?PaneMousePlan {
    const tab_id = model.tabs.location[slot].tab_id;
    const layout_snapshot = snapshot(model, slot, area);
    const wheel = event.kind == .scroll_up or event.kind == .scroll_down;
    var pane = focusedPane(model, slot) orelse return null;
    if (wheel) {
        for (layout_snapshot.views()) |candidate| {
            if (!candidate.content.contains(event.x, event.y)) {
                continue;
            }

            pane = model.panes.findIn(tab_id, candidate.pane_id) orelse return null;
            break;
        }
    }

    const pane_view = layout_snapshot.find(pane.id) orelse return null;
    if (!pane_view.content.contains(event.x, event.y)) {
        return null;
    }

    return paneMousePlan(pane, pane_view.content);
}

/// Resolves the focused pane without consulting pointer coordinates.
/// Example: `const plan = tab_layout.planFocusedPaneMouse(model, slot, area) orelse return;`
pub fn planFocusedPaneMouse(model: *Model, slot: usize, area: core.Rect) ?PaneMousePlan {
    const pane = focusedPane(model, slot) orelse return null;
    const pane_view = view(model, slot, pane.id, area) orelse return null;
    if (pane_view.content.w == 0 or pane_view.content.h == 0) {
        return null;
    }

    return paneMousePlan(pane, pane_view.content);
}

/// Captures the mouse policy of an already resolved pane.
/// Example: `const plan = tab_layout.paneMousePlan(pane, view.content);`
pub fn paneMousePlan(pane: *const Pane, content: core.Rect) PaneMousePlan {
    return .{
        .pane_id = pane.id,
        .content = content,
        .protocol = pane.mouse,
        .alternate_scroll = pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll,
        .at_bottom = pane.scroll.atBottom(pane.buffer.h),
    };
}

/// Orders the tab's panes like the runtime's display order.
/// Example: `try tab_layout.restoreDisplayOrder(model, slot, pane_ids, focused);`
pub fn restoreDisplayOrder(model: *Model, slot: usize, pane_ids: []const core.PaneId, focused: core.PaneId) !void {
    const tab_id = model.tabs.location[slot].tab_id;
    if (pane_ids.len != model.panes.countIn(tab_id)) {
        return error.UnexpectedPaneCount;
    }

    for (pane_ids) |pane_id| {
        if (model.panes.findIn(tab_id, pane_id) == null) {
            return error.PaneNotFound;
        }
    }

    try model.tabs.layout[slot].restoreDisplayOrder(pane_ids, focused);
}

/// Restores a saved split tree when it matches the tab's pane membership.
/// Example: `const restored = tab_layout.restoreSaved(model, slot, saved, panes);`
pub fn restoreSaved(model: *Model, slot: usize, saved: WorkspaceLayout, panes: PaneSet) bool {
    const tab_id = model.tabs.location[slot].tab_id;
    if (panes.ids.len != model.panes.countIn(tab_id)) {
        return false;
    }

    for (panes.ids) |pane_id| {
        if (model.panes.findIn(tab_id, pane_id) == null) {
            return false;
        }
    }

    return model.tabs.layout[slot].restoreSaved(saved, panes);
}

/// Adds the first pane of an empty tab.
/// Example: `try tab_layout.addRoot(model, slot, .{ .pane_id = id, .location = location, .size = size });`
pub fn addRoot(model: *Model, slot: usize, spec: Spec) !void {
    if (model.panes.countIn(model.tabs.location[slot].tab_id) != 0) {
        return error.ModelNotEmpty;
    }

    _ = try model.panes.add(model.gpa, spec, true);
    errdefer _ = model.panes.remove(spec.pane_id);
    try model.tabs.layout[slot].addRoot(spec.pane_id);
}

/// Removes one pane from its tab and its layout.
/// Example: `_ = tab_layout.removePane(model, pane_id);`
pub fn removePane(model: *Model, pane_id: core.PaneId) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    const slot = model.tabs.find(pane.location.tab_id);
    _ = model.panes.remove(pane_id);
    if (slot) |tab| {
        _ = model.tabs.layout[tab].remove(pane_id);
    }

    return true;
}

/// Sets the pane-gap preference on every tab.
/// Example: `tab_layout.setPaneGaps(model, true);`
pub fn setPaneGaps(model: *Model, enabled: bool) void {
    model.pane_gaps = enabled;
    for (model.tabs.layout[0..model.tabs.count]) |*layout| {
        _ = layout.setPaneGaps(enabled);
    }
}
