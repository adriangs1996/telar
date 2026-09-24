//! Which panes a client attaches, their attachment generations and the agent markers they carry.

const std = @import("std");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Resolves the focused pane to an attachment-capable agent identity.
/// Agents whose manifest declares no attachment markers have no image shelf.
///
/// ```zig
/// const key = pane_attachment.focusedAgent(model) orelse return;
/// ```
pub fn focusedAgent(model: *const ClientModel) ?model_data.AgentKey {
    const slot = model.tabs.activeSlot() orelse return null;
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    const key = model.agent_snapshot.keyForPane(model.tabs.location[slot], pane_id) orelse return null;
    const agent = model.agent_snapshot.find(key).?;
    if (agent.attachments == .none) {
        return null;
    }

    return key;
}

/// Resolves the focused attachment-capable agent to its capture target.
///
/// ```zig
/// const target = pane_attachment.focusedTarget(model) orelse return;
/// ```
pub fn focusedTarget(model: *const ClientModel) ?model_data.AttachmentTarget {
    const key = focusedAgent(model) orelse return null;

    return .{
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
    };
}

/// Resolves the marker scheme only while the exact pane generation still
/// owns an attachment-capable agent.
///
/// ```zig
/// const markers = pane_attachment.markersFor(model, target) orelse return;
/// ```
pub fn markersFor(model: *const ClientModel, target: model_data.AttachmentTarget) ?core.AgentAttachmentMarkers {
    const agent = model.agent_snapshot.find(.{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
    }) orelse return null;

    return if (agent.attachments == .none) null else agent.attachments;
}

/// Confirms a client attachment only while the requested pane is still
/// detached in the active tab. Attachment state is operational and does
/// not advance a presentation revision.
///
/// ```zig
/// const result = pane_attachment.confirm(model, attachment);
/// ```
pub fn confirm(model: *ClientModel, attachment: model_data.PaneAttachment) !model_data.AttachmentConfirmation {
    const active = model.activeTabLocation() orelse return .stale;
    if (!std.meta.eql(active, attachment.location)) {
        return .stale;
    }

    const pane = model.panes.findIn(active.tab_id, attachment.pane_id) orelse return .stale;
    if (!std.meta.eql(pane.location, attachment.location) or pane.attached) {
        return .stale;
    }

    pane.attach(try allocateGeneration(model));
    return .confirmed;
}

pub fn allocateGeneration(model: *ClientModel) !u64 {
    if (model.next_attachment_generation == std.math.maxInt(u64)) {
        return error.AttachmentGenerationExhausted;
    }

    const generation = model.next_attachment_generation;
    model.next_attachment_generation += 1;
    return generation;
}

/// Reports whether the active client replica still needs the requested
/// attachment. Stale tabs, missing panes and confirmed panes need no repair.
///
/// ```zig
/// if (pane_attachment.needsAttachment(model, attachment)) requestSnapshot();
/// ```
pub fn needsAttachment(model: *const ClientModel, attachment: model_data.PaneAttachment) bool {
    const active = model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, attachment.location)) {
        return false;
    }

    const pane = model.panes.findInConst(active.tab_id, attachment.pane_id) orelse return false;
    return std.meta.eql(pane.location, attachment.location) and !pane.attached;
}
