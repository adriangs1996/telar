//! Pane focus: moves focus between panes and reports focus changes to the
//! children that asked for them.
const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const actions = @import("../input/actions.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_input = @import("pane_input.zig");
const pane_resize = @import("pane_resize.zig");
const Client = @import("../execution/Client.zig");

const FocusReportOutcome = enum { applied, unchanged };

/// Synchronizes the focused attachment before reporting child focus. Example: `try pane_focus.synchronizeActivePane(client);`
pub fn synchronizeActivePane(client: *Client) !void {
    _ = try pane_attachment.synchronizePaneAttachments(client);
    _ = try synchronizeReportedFocus(&client.model);
}

/// Commits focus before synchronizing attachments and child focus.
/// Example: `_ = try pane_focus.applyPaneFocus(client, command);`
pub fn applyPaneFocus(client: *Client, command: data.PaneFocusRequest) !?data.PaneFocus {
    const focus = client.model.focusPane(command) orelse return null;
    try deliverPaneFocus(client, focus, command.area);

    return focus;
}

/// Delivers resources for a committed focus, including newly revealed panes. Example: `try pane_focus.deliverPaneFocus(client, focus, area);`
pub fn deliverPaneFocus(client: *Client, focus: data.PaneFocus, area: cellgrid.Rect) !void {
    const active = client.model.tabs.activeSlot() orelse return error.StalePaneFocus;
    if (!std.meta.eql(client.model.tabs.location[active], focus.location) or
        client.model.tabs.layout[active].focused() != focus.focused or
        client.model.version().panes != focus.panes_revision)
    {
        return error.StalePaneFocus;
    }

    try synchronizeActivePane(client);
    if (!focus.geometry_changed) {
        return;
    }

    client.model.to_host.invalidate_placements = true;
    try pane_resize.resizeAttachedPanes(client, active, area);

    if (client.model.tabs.snapshot_loaded[active]) {
        try pane_attachment.attachVisiblePanes(&client.model, active, area);
    }
}

pub fn navigatePane(client: *Client, direction: data.InputDirection) !void {
    const key = actions.navigationKey(direction);
    if (std.mem.eql(
        u8,
        client.model.focusedPaneForeground(),
        "nvim",
    )) {
        _ = try pane_input.sendPaneInput(
            client,
            .{
                .target = .focused,
                .source = .host,
                .payload = .{
                    .key = key,
                },
            },
        );
        return;
    }

    _ = try applyPaneFocus(
        client,
        .{
            .target = .{
                .direction = switch (direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                },
            },
            .area = client.geometry().area,
        },
    );
}

/// Revalidates the source pane, applies the directional focus, and reports the
/// result to the control connection through the runtime.
pub fn completePaneFocusCommand(client: *Client, command: core.PaneFocusCommand) !void {
    const current = client.model.planPaneInput(.focused);
    if (current == null or current.?.pane_id != command.pane_id) {
        return sendPaneFocusCompletion(
            &client.model,
            command,
            .{
                .outcome = .source_not_focused,
                .focused_pane_id = .invalid,
            },
        );
    }

    const focus = try applyPaneFocus(
        client,
        .{
            .target = .{
                .direction = paneFocusDirection(command.direction),
            },
            .area = client.geometry().area,
        },
    );
    if (focus) |changed| {
        return sendPaneFocusCompletion(
            &client.model,
            command,
            .{
                .outcome = .focused,
                .focused_pane_id = changed.focused,
            },
        );
    }

    return sendPaneFocusCompletion(
        &client.model,
        command,
        .{
            .outcome = .no_neighbor,
            .focused_pane_id = command.pane_id,
        },
    );
}

fn sendPaneFocusCompletion(model: *data.ClientModel, command: core.PaneFocusCommand, completion: data.PaneFocusCompletion) !void {
    try model.to_runtime.push(
        .{
            .complete_pane_focus = .{
                .requester = command.requester,
                .request_id = command.request_id,
                .pane_id = command.pane_id,
                .pane_generation = command.pane_generation,
                .outcome = completion.outcome,
                .focused_pane_id = completion.focused_pane_id,
            },
        },
    );
}

fn paneFocusDirection(value: core.PaneDirection) data.LayoutDirection {
    return switch (value) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}

/// Commits reporting ownership before emitting focus-out and focus-in. Example: `_ = try sync(client);`
fn synchronizeReportedFocus(model: *data.ClientModel) !FocusReportOutcome {
    const transition = model.syncReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try runtime_io.sendRuntimeInput(
            model,
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[O",
            },
        );
    }

    if (transition.focus_in) |pane_id| {
        try runtime_io.sendRuntimeInput(
            model,
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[I",
            },
        );
    }

    return .applied;
}

/// Clears focus ownership before detachment and sends the matching focus-out. Example: `_ = try clear(client);`
pub fn clearReportedFocus(model: *data.ClientModel) !FocusReportOutcome {
    const transition = model.clearReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try runtime_io.sendRuntimeInput(
            model,
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[O",
            },
        );
    }

    return .applied;
}
