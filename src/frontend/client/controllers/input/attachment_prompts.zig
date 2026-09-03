//! Binds Telar's local image previews to Codex, Claude and Pi prompt markers.

const std = @import("std");
const core = @import("telar-core");
const attachments = @import("../../../attachments/root.zig");
const input_capability = @import("../../../input/root.zig");
const input_application = @import("../../application/input/root.zig");
const pane_inputs = @import("pane_inputs.zig");

const Client = @import("../../client.zig");
const attachment_prompt = input_application.attachment_prompt;
const key_routing = input_application.key_routing;
const pane_input = input_application.pane_input;
const schema = core.schema;

const max_removal_keys = attachments.max_removal_keys;

comptime {
    std.debug.assert(max_removal_keys <= pane_input.max_keys);
}

/// Deletes the paired child marker and then retires one local preview.
///
/// ```zig
/// const layout_changed = try dismiss(client, id);
/// ```
pub fn dismiss(client: *Client, id: attachments.Id) !bool {
    var use_case: attachment_prompt.DismissAttachmentHandler = .{ .effects = .{
        .context = client,
        .plan = planRemoval,
        .deliver = deliverRemoval,
        .remove = removeAttachment,
    } };

    return use_case.execute(id);
}

/// Mirrors one successfully delivered Backspace, Delete or Enter into the
/// preview collection owned by that pane.
///
/// ```zig
/// const layout_changed = observe(client, pane_id, command);
/// ```
pub fn observe(client: *Client, pane_id: schema.PaneId, command: key_routing.Command) bool {
    expectMarkerDeletion(client, pane_id, command);
    var use_case: attachment_prompt.ObservePaneInputHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .visible_target = visibleTarget,
            .marker_at_cursor = markerAtCursor,
            .pending_marker_at_cursor = pendingMarkerAtCursor,
            .remove = removeAttachment,
            .remove_prompt = removePrompt,
        },
    };

    return use_case.execute(pane_id, command);
}

fn expectMarkerDeletion(client: *Client, pane_id: schema.PaneId, command: key_routing.Command) void {
    const key = switch (command) {
        .bytes => return,
        .key => |value| value,
    };
    const target = client.view.kittyAttachments().visibleTarget() orelse return;
    if (target.pane_id != pane_id) {
        return;
    }

    const policy = learnedPolicy(client, target) orelse return;
    if (!attachment_prompt.editsMarkers(policy, key)) {
        return;
    }

    client.view.kittyAttachments().expectMarkerDeletion(target);
}

/// Resolves the marker policy of a target whose provider learns marker
/// identities from committed frames.
fn learnedPolicy(client: *Client, target: attachments.Target) ?attachments.MarkerPolicy {
    const markers = client.model.attachmentMarkers(target) orelse return null;
    const policy = attachment_prompt.markerPolicy(markers);

    return if (policy.learnsIdentity()) policy else null;
}

/// Reconciles learned attachment identities (Claude numbers, Pi paths)
/// after one pane frame.
///
/// ```zig
/// const layout_changed = reconcileFrame(client, pane_id);
/// ```
pub fn reconcileFrame(client: *Client, pane_id: schema.PaneId) bool {
    const target = client.view.kittyAttachments().visibleTarget() orelse return false;
    if (target.pane_id != pane_id or learnedPolicy(client, target) == null) {
        return false;
    }

    const tab = client.model.workspace.tabForPaneConst(pane_id) orelse return false;
    const pane = tab.model.findConst(pane_id) orelse return false;

    return client.view.reconcileAttachmentMarkers(target, .{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }) orelse false;
}

fn planRemoval(raw_context: *anyopaque, id: attachments.Id) ?attachment_prompt.RemovalCommand {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.view.kittyAttachments().visibleTarget() orelse return null;
    const model = client.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(target.pane_id) orelse return null;
    const marker = client.view.kittyAttachments().planMarkerRemoval(id, .{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }) orelse return null;

    return .{ .pane_id = target.pane_id, .marker = marker };
}

fn deliverRemoval(raw_context: *anyopaque, command: attachment_prompt.RemovalCommand) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var keys: [max_removal_keys]input_capability.Key = undefined;
    var len: usize = 0;
    const movement: input_capability.Key.Code = switch (command.marker.direction) {
        .left => .left,
        .right => .right,
    };
    const restoration: input_capability.Key.Code = switch (command.marker.direction) {
        .left => .right,
        .right => .left,
    };
    for (0..command.marker.steps) |_| {
        keys[len] = .{ .code = movement };
        len += 1;
    }

    for (0..command.marker.deletions) |_| {
        keys[len] = .{ .code = switch (command.marker.deletion) {
            .backward => .backspace,
            .forward => .delete,
        } };
        len += 1;
    }

    for (0..command.marker.steps) |_| {
        keys[len] = .{ .code = restoration };
        len += 1;
    }

    _ = try pane_inputs.sendKeys(client, .{ .pane = command.pane_id }, keys[0..len]) orelse
        return error.AttachmentMarkerDeliveryUnavailable;
}

fn visibleTarget(raw_context: *anyopaque) ?attachments.Target {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.view.kittyAttachments().visibleTarget();
}

fn markerAtCursor(raw_context: *anyopaque, deletion: attachments.MarkerDeletion) ?attachments.Id {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.view.kittyAttachments().visibleTarget() orelse return null;
    const model = client.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(target.pane_id) orelse return null;

    return client.view.kittyAttachments().idAtMarkerDeletion(.{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }, deletion);
}

fn pendingMarkerAtCursor(raw_context: *anyopaque, deletion: attachments.MarkerDeletion) bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.model.focusedAttachmentTarget() orelse return false;
    const model = client.model.activeTabModelConst() orelse return false;
    const pane = model.findConst(target.pane_id) orelse return false;

    const markers = client.model.attachmentMarkers(target) orelse return false;

    return client.view.kittyAttachments().pendingMarkerAtDeletion(.{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }, .{ .deletion = deletion, .policy = attachment_prompt.markerPolicy(markers) });
}

fn removeAttachment(raw_context: *anyopaque, id: attachments.Id) ?bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.view.removeAttachment(id);
}

fn removePrompt(raw_context: *anyopaque, target: attachments.Target) ?bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.view.removePromptAttachments(target);
}
