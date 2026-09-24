//! A new pane splits an existing one (docs/flows/pane-split.md).
const pane_attachment = @import("../panes/pane_attachment.zig");
const RecoverPaneSplit = @import("../state/RecoverPaneSplit.zig");
const PaneSplitCommitState = @import("../state/PaneSplitCommitState.zig");
const CommitPaneSplit = @import("../state/CommitPaneSplit.zig");
const multiplexer_module = @import("multiplexer.zig");
const pane_split = @import("pane_split.zig");
const tab_snapshot_reconciliation = @import("tab_snapshot_reconciliation.zig");
const model_namespace = @import("../state/model_namespace.zig");
const AgentPane = @import("../panes/Pane.zig");
const model_data = @import("../model.zig");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const PaneSplit = @import("PaneSplit.zig");
const multiplexer = @import("multiplexer.zig");
const tab_layout = @import("tab_layout.zig");

/// Adds `request.new_pane` beside `request.existing_pane` in tab `slot`.
/// Example: `try pane_split.split(model, slot, request);`
pub fn split(model: *ClientModel, slot: usize, request: PaneSplit) !void {
    const prospective = tab_layout.prospectiveSplit(
        model,
        slot,
        .{
            .pane_id = request.existing_pane,
            .axis = request.axis,
        },
        request.area,
    ) orelse return error.PaneTooSmall;
    const size = multiplexer.rectSize(prospective.new_content) orelse return error.PaneTooSmall;

    _ = try model.panes.add(
        model.gpa,
        .{
            .pane_id = request.new_pane,
            .location = request.location,
            .size = size,
        },
        true,
    );
    errdefer _ = model.panes.remove(request.new_pane);
    try model.tabs.layout[slot].split(.{
        .existing_pane = request.existing_pane,
        .new_pane = request.new_pane,
        .axis = request.axis,
    });
}

test {
    std.testing.refAllDecls(@This());
}

/// Plans one split from active client state without changing the semantic
/// model. Both provisional sizes inherit the current cell pixel geometry.
///
/// ```zig
/// const plan = pane_split.planSplit(model, .{ .axis = .horizontal, .area = area }) orelse return;
/// ```
pub fn planSplit(model: *ClientModel, request: model_data.RequestPaneSplit) ?model_data.PaneSplitPlan {
    const slot = model.tabs.activeSlot() orelse return null;
    const location = model.tabs.location[slot];
    const target: *const AgentPane = (if (request.target_pane) |id| model.panes.findInConst(location.tab_id, id) else tab_layout.focusedPaneConst(model, slot)) orelse return null;
    if (!target.attached or !std.meta.eql(target.location, location)) {
        return null;
    }

    const restore_size = tab_layout.contentSize(model, slot, target.id, request.area) orelse return null;
    const prospective = tab_layout.prospectiveSplit(model, slot, .{ .pane_id = target.id, .axis = request.axis }, request.area) orelse
        return null;
    var provisional_size = multiplexer_module.rectSize(prospective.existing_content) orelse return null;
    var new_pane_size = multiplexer_module.rectSize(prospective.new_content) orelse return null;
    model_namespace.inheritCellSize(&provisional_size, restore_size);
    model_namespace.inheritCellSize(&new_pane_size, restore_size);

    return .{
        .split = .{
            .target_pane = target.id,
            .location = location,
            .axis = request.axis,
            .area = request.area,
        },
        .provisional_resize = .{ .pane_id = target.id, .size = provisional_size },
        .restore_resize = .{ .pane_id = target.id, .size = restore_size },
        .new_pane_size = new_pane_size,
        .arguments = request.arguments,
    };
}

/// Commits a runtime-created pane into the exact tab that requested it.
/// A missing target is a recoverable race; a missing tab leaves the pane
/// unrepresented so the client adapter can detach its runtime attachment.
///
/// ```zig
/// const commit = try pane_split.commitSplit(model, command);
/// ```
pub fn commitSplit(model: *ClientModel, command: CommitPaneSplit) !model_data.PaneSplitCommit {
    const stale = finishSplit(model, command, .{
        .disposition = .stale,
        .change = .unchanged,
        .layout_revision = 0,
    });
    const workspace = model.workspace orelse return stale;
    if (!std.meta.eql(workspace, command.split.location.workspace)) {
        return stale;
    }

    const tab = model_namespace.findTab(model, command.split.location) orelse return stale;
    const tab_id = command.split.location.tab_id;
    const active = if (model.activeTabLocation()) |current|
        std.meta.eql(current, command.split.location)
    else
        false;
    if (model.panes.find(command.new_pane)) |pane| {
        if (pane.location.tab_id != tab_id or command.new_pane == command.split.target_pane) {
            return error.PaneAlreadyExists;
        }

        if (active) {
            if (!pane.attached) {
                pane.attach(try pane_attachment.allocateGeneration(model));
            }
        } else {
            model_namespace.detachPane(pane);
        }

        return finishSplit(model, command, .{
            .disposition = if (active) .active else .inactive,
            .change = .unchanged,
            .layout_revision = model.tabs.layout[tab].currentRevision(),
        });
    }

    if (model.panes.findIn(tab_id, command.split.target_pane) != null) {
        try pane_split.split(model, tab, .{ .existing_pane = command.split.target_pane, .new_pane = command.new_pane, .location = command.split.location, .axis = command.split.axis, .area = command.split.area });
    } else {
        try tab_snapshot_reconciliation.addDiscovered(model, tab, .{ .pane_id = command.new_pane, .location = command.split.location, .area = command.split.area });
        model.panes.find(command.new_pane).?.attach(try pane_attachment.allocateGeneration(model));
    }

    if (!active) {
        model_namespace.detachPane(model.panes.find(command.new_pane).?);
    } else {
        model.panes_revision +%= 1;
    }

    return finishSplit(model, command, .{
        .disposition = if (active) .active else .inactive,
        .change = if (active) .changed else .unchanged,
        .layout_revision = model.tabs.layout[tab].currentRevision(),
    });
}

/// Resolves failure rollback against current state rather than whichever
/// tab happens to be active when the response arrives.
///
/// ```zig
/// const recovery = pane_split.recover(model, .{ .split = split, .area = area });
/// ```
pub fn recover(model: *ClientModel, command: RecoverPaneSplit) model_data.PaneSplitRecovery {
    const workspace = model.workspace orelse return .stale;
    if (!std.meta.eql(workspace, command.split.location.workspace)) {
        return .stale;
    }

    const tab = model_namespace.findTab(model, command.split.location) orelse return .stale;
    const pane = model.panes.findIn(command.split.location.tab_id, command.split.target_pane) orelse return .stale;
    if (!std.meta.eql(pane.location, command.split.location)) {
        return .stale;
    }

    const active = model.activeTabLocation() orelse return .stale;
    if (!std.meta.eql(active, command.split.location) or !pane.attached) {
        return .not_required;
    }

    const size = tab_layout.contentSize(model, tab, command.split.target_pane, command.area) orelse
        return .not_required;
    return .{ .resize = .{ .pane_id = command.split.target_pane, .size = size } };
}

fn finishSplit(model: *const ClientModel, command: CommitPaneSplit, state: PaneSplitCommitState) model_data.PaneSplitCommit {
    return .{
        .pane_id = command.new_pane,
        .location = command.split.location,
        .area = command.split.area,
        .disposition = state.disposition,
        .change = state.change,
        .layout_revision = state.layout_revision,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    };
}
