//! Binds Telar's local image previews to Codex, Claude and Pi prompt markers.

const std = @import("std");
const max_removal_keys = @import("../../attachments/types.zig").max_removal_keys;
const max_keys_module = @import("../../application/input/pane_input.zig").max_keys;
const Client = @import("../../AttachedClient.zig");
const AttachmentsTypesId = @import("../../attachments/types.zig").Id;
const DismissAttachmentHandlerType = @import("../../application/input/DismissAttachmentHandler.zig");
const PaneIdType = @import("telar-core").PaneId;
const ApplicationInputKeyRoutingCommand = @import("../../application/input/key_routing.zig").Command;
const ObservePaneInputHandlerType = @import("../../application/input/ObservePaneInputHandler.zig");
const editsMarkers_module = @import("../../application/input/attachment_prompt.zig").editsMarkers;
const TargetType = @import("../../attachments/AttachmentTarget.zig");
const MarkerPolicyType = @import("../../attachments/types.zig").MarkerPolicy;
const markerPolicy_module = @import("../../application/input/attachment_prompt.zig").markerPolicy;
const RemovalCommandType = @import("../../application/input/RemovalCommand.zig");
const KeyType = @import("../../input/Key.zig");
const pane_inputs = @import("pane_inputs.zig");
const MarkerDeletionType = @import("../../attachments/types.zig").MarkerDeletion;
const backslashContinuesPrompt_module = @import("../../application/input/attachment_prompt.zig").backslashContinuesPrompt;
const promptContinuesAtCursor_module = @import("../../attachments/markers.zig").promptContinuesAtCursor;

comptime {
    std.debug.assert(max_removal_keys <= max_keys_module);
}

/// Deletes the paired child marker and then retires one local preview.
///
/// ```zig
/// const layout_changed = try dismiss(client, id);
/// ```
pub fn dismiss(client: *Client, id: AttachmentsTypesId) !bool {
    var use_case: DismissAttachmentHandlerType = .{ .effects = .{
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
pub fn observe(client: *Client, pane_id: PaneIdType, command: ApplicationInputKeyRoutingCommand) bool {
    expectMarkerDeletion(client, pane_id, command);
    var use_case: ObservePaneInputHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .visible_target = visibleTarget,
            .marker_at_cursor = markerAtCursor,
            .pending_marker_at_cursor = pendingMarkerAtCursor,
            .prompt_continues = promptContinues,
            .remove = removeAttachment,
            .remove_prompt = removePrompt,
        },
    };

    return use_case.execute(pane_id, command);
}

fn expectMarkerDeletion(client: *Client, pane_id: PaneIdType, command: ApplicationInputKeyRoutingCommand) void {
    const key = switch (command) {
        .bytes => return,
        .key => |value| value,
    };
    const target = client.attachment_catalog.visibleTarget() orelse return;
    if (target.pane_id != pane_id) {
        return;
    }

    const policy = learnedPolicy(client, target) orelse return;
    if (!editsMarkers_module(policy, key)) {
        return;
    }

    client.attachment_catalog.expectMarkerDeletion(target);
}

/// Resolves the marker policy of a target whose provider learns marker
/// identities from committed frames.
fn learnedPolicy(client: *Client, target: TargetType) ?MarkerPolicyType {
    const markers = client.model.attachmentMarkers(target) orelse return null;
    const policy = markerPolicy_module(markers);

    return if (policy.learnsIdentity()) policy else null;
}

/// Reconciles learned attachment identities (Claude numbers, Pi paths)
/// after one pane frame.
///
/// ```zig
/// const layout_changed = reconcileFrame(client, pane_id);
/// ```
pub fn reconcileFrame(client: *Client, pane_id: PaneIdType) bool {
    const target = client.attachment_catalog.visibleTarget() orelse return false;
    if (target.pane_id != pane_id or learnedPolicy(client, target) == null) {
        return false;
    }

    const tab = client.model.workspace.tabForPaneConst(pane_id) orelse return false;
    const pane = tab.model.findConst(pane_id) orelse return false;

    return client.attachment_shelf.reconcileMarkers(target, .{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }) orelse false;
}

fn planRemoval(raw_context: *anyopaque, id: AttachmentsTypesId) ?RemovalCommandType {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.attachment_catalog.visibleTarget() orelse return null;
    const model = client.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(target.pane_id) orelse return null;
    const marker = client.attachment_catalog.planMarkerRemoval(id, .{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }) orelse return null;

    return .{ .pane_id = target.pane_id, .marker = marker };
}

fn deliverRemoval(raw_context: *anyopaque, command: RemovalCommandType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var keys: [max_removal_keys]KeyType = undefined;
    var len: usize = 0;
    const movement: KeyType.Code = switch (command.marker.direction) {
        .left => .left,
        .right => .right,
    };
    const restoration: KeyType.Code = switch (command.marker.direction) {
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

fn visibleTarget(raw_context: *anyopaque) ?TargetType {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.attachment_catalog.visibleTarget();
}

fn markerAtCursor(raw_context: *anyopaque, deletion: MarkerDeletionType) ?AttachmentsTypesId {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.attachment_catalog.visibleTarget() orelse return null;
    const model = client.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(target.pane_id) orelse return null;

    return client.attachment_catalog.idAtMarkerDeletion(.{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }, deletion);
}

fn pendingMarkerAtCursor(raw_context: *anyopaque, deletion: MarkerDeletionType) bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const target = client.model.focusedAttachmentTarget() orelse return false;
    const model = client.model.activeTabModelConst() orelse return false;
    const pane = model.findConst(target.pane_id) orelse return false;

    const markers = client.model.attachmentMarkers(target) orelse return false;

    return client.attachment_catalog.pendingMarkerAtDeletion(.{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    }, .{ .deletion = deletion, .policy = markerPolicy_module(markers) });
}

/// Reports whether the accepted Enter continues the prompt instead of
/// submitting it: the agent's editor treats a trailing backslash as a
/// newline request.
fn promptContinues(raw_context: *anyopaque, target: TargetType) bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const markers = client.model.attachmentMarkers(target) orelse return false;
    if (!backslashContinuesPrompt_module(markerPolicy_module(markers))) {
        return false;
    }

    const model = client.model.activeTabModelConst() orelse return false;
    const pane = model.findConst(target.pane_id) orelse return false;

    return promptContinuesAtCursor_module(.{
        .buffer = &pane.buffer,
        .cursor = pane.cursor,
    });
}

fn removeAttachment(raw_context: *anyopaque, id: AttachmentsTypesId) ?bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.attachment_shelf.remove(id);
}

fn removePrompt(raw_context: *anyopaque, target: TargetType) ?bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.attachment_shelf.removePrompt(target);
}
