//! Detaching a tab from this client.

const TabDetachmentPlan = @import("../state/TabDetachmentPlan.zig");
const model_namespace = @import("../state/model_namespace.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Captures one exact tab's operational attachments and whether it owns
/// the current paste or reported focus authority.
///
/// ```zig
/// const plan = try client_detach.planTabDetachment(model, location);
/// ```
pub fn planTabDetachment(model: *const ClientModel, location: core.TabLocation) !TabDetachmentPlan {
    _ = model_namespace.findTab(model, location) orelse return error.UnexpectedTab;
    var plan: TabDetachmentPlan = .{ .location = location };

    var panes = model.panes.iterateConst(location.tab_id);
    while (panes.next()) |pane| {
        plan.panes[plan.len] = .{
            .pane_id = pane.id,
            .attached = pane.attached,
        };
        plan.len += 1;
    }

    if (model.pane_paste) |session| {
        if (model.panes.findInConst(location.tab_id, session.pane_id) != null) {
            plan.owns_paste = true;
            plan.paste_marker_required = session.bracketed_paste;
        }
    }

    if (model.reported_pane_focus) |reported| {
        if (model.panes.findInConst(location.tab_id, reported.pane_id)) |pane| {
            plan.owns_reported_focus = true;
            plan.focus_out_required = reported.focus_events and pane.attached;
        }
    }

    return plan;
}

/// Clears only the operational attachments captured by an unchanged
/// synchronous plan. This transition advances no presentation revision.
///
/// ```zig
/// try client_detach.commitTabDetachment(model, plan);
/// ```
pub fn commitTabDetachment(model: *ClientModel, plan: TabDetachmentPlan) !void {
    if (plan.len > core.max_panes_per_tab) {
        return error.InvalidTabDetachment;
    }

    _ = model_namespace.findTab(model, plan.location) orelse return error.StaleTabDetachment;
    const tab_id = plan.location.tab_id;
    if (model.panes.countIn(tab_id) != plan.len) {
        return error.StaleTabDetachment;
    }

    for (plan.slice(), 0..) |planned, index| {
        for (plan.slice()[0..index]) |previous| {
            if (previous.pane_id == planned.pane_id) {
                return error.InvalidTabDetachment;
            }
        }

        const pane = model.panes.findIn(tab_id, planned.pane_id) orelse return error.StaleTabDetachment;
        if (pane.attached != planned.attached) {
            return error.StaleTabDetachment;
        }
    }

    for (plan.slice()) |planned| {
        model_namespace.detachPane(model.panes.findIn(tab_id, planned.pane_id).?);
    }
}
