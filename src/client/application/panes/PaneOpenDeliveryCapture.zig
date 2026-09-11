const pane_open_delivery = @import("pane_open_delivery.zig");
const OpenedPane = @import("OpenedPane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const PaneSplitType = @import("../../model/PaneSplit.zig");
const PaneAttachmentType = @import("../../model/PaneAttachment.zig");
const PaneOpenDeliveryEffects = @import("PaneOpenDeliveryEffects.zig");
const WorkspaceCreation = @import("WorkspaceCreation.zig");
const PaneSplitConfirmation = @import("PaneSplitConfirmation.zig");
const PaneAttachmentConfirmation = @import("PaneAttachmentConfirmation.zig");
const Capture = @This();

effect: ?pane_open_delivery.Effect = null,
opened: ?OpenedPane = null,
requested_size: ?TerminalSizeType = null,
split: ?PaneSplitType = null,
attachment: ?PaneAttachmentType = null,
failure: ?pane_open_delivery.Effect = null,

pub fn effects(capture: *Capture) PaneOpenDeliveryEffects {
    return .{
        .context = capture,
        .arrive_workspace = arriveWorkspace,
        .create_workspace = createWorkspace,
        .confirm_split = confirmSplit,
        .confirm_attachment = confirmAttachment,
    };
}

fn arriveWorkspace(raw_context: *anyopaque, opened: OpenedPane) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    try capture.record(.arrive_workspace, opened);
}

fn createWorkspace(raw_context: *anyopaque, confirmation: WorkspaceCreation) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.requested_size = confirmation.requested_size;
    try capture.record(.create_workspace, confirmation.opened);
}

fn confirmSplit(raw_context: *anyopaque, confirmation: PaneSplitConfirmation) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.split = confirmation.requested;
    try capture.record(.confirm_split, confirmation.opened);
}

fn confirmAttachment(raw_context: *anyopaque, confirmation: PaneAttachmentConfirmation) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.attachment = confirmation.requested;
    try capture.record(.confirm_attachment, confirmation.opened);
}

fn record(capture: *Capture, effect: pane_open_delivery.Effect, opened: OpenedPane) !void {
    capture.effect = effect;
    capture.opened = opened;

    if (capture.failure == effect) {
        return error.DeliveryFailed;
    }
}

pub fn reset(capture: *Capture) void {
    capture.effect = null;
    capture.opened = null;
    capture.requested_size = null;
    capture.split = null;
    capture.attachment = null;
}
