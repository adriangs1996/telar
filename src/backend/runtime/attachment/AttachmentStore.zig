const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const IteratorType = @import("Iterator.zig");
const Attachment = @import("Attachment.zig");
const GenericSlotIndex = @import("telar-core").GenericSlotIndex;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneIdType = @import("telar-core").PaneId;
const raw_module = @import("telar-core").raw;
const std = @import("std");
const GraphicsCreditType = @import("telar-core").GraphicsCredit;
const attachment_namespace = @import("attachment_namespace.zig");
const FrameAckType = @import("telar-core").FrameAck;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const SelectionQuery = @import("SelectionQuery.zig");
const selection = @import("selection.zig");
const PaneType = @import("../../pane/Pane.zig");
const PaneDetached = @import("PaneDetached.zig");
const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
pub const AttachmentStore = @This();

pub const capacity = @import("telar-core").max_panes_per_tab;
pub const Iterator = @import("Iterator.zig");

items: [max_panes_per_tab]?Attachment = [_]?Attachment{null} ** max_panes_per_tab,
count: usize = 0,
index: GenericSlotIndex(2 * max_panes_per_tab) = .{},
workspace: ?WorkspaceLocationType = null,
shared_graphics: bool = false,

pub fn find(store: *AttachmentStore, pane_id: PaneIdType) ?*Attachment {
    const slot = store.index.get(raw_module(pane_id)) orelse return null;
    const attachment = &store.items[slot].?;
    std.debug.assert(attachment.pane.id == pane_id);
    return attachment;
}

/// Coalesces a full cell-snapshot request into the selected client
/// attachment. Missing panes leave every attachment unchanged.
///
/// ```zig
/// if (!store.requestCellSnapshot(pane_id)) {
///     recordStaleMessage();
/// }
/// ```
pub fn requestCellSnapshot(store: *AttachmentStore, pane_id: PaneIdType) bool {
    const attachment = store.find(pane_id) orelse return false;
    attachment.requestCellSnapshot();
    return true;
}

/// Replaces one client's graphics baseline with a complete snapshot. Any
/// frozen transfer is released before the recovery mark becomes visible;
/// repeated requests coalesce and retain transport policy and credit.
///
/// ```zig
/// if (!store.requestGraphicsSnapshot(pane_id)) {
///     recordStaleMessage();
/// }
/// ```
pub fn requestGraphicsSnapshot(store: *AttachmentStore, pane_id: PaneIdType) bool {
    const attachment = store.find(pane_id) orelse return false;
    attachment.requestGraphicsSnapshot();
    return true;
}

/// Restores only graphics bytes previously consumed by one client
/// attachment. Invalid amounts and missing panes leave all credit unchanged.
///
/// ```zig
/// const update = store.returnGraphicsCredit(credit);
/// ```
pub fn returnGraphicsCredit(store: *AttachmentStore, credit: GraphicsCreditType) attachment_namespace.GraphicsCreditUpdate {
    const attachment = store.find(credit.pane_id) orelse return .pane_not_attached;
    const bytes = std.math.cast(usize, credit.bytes) orelse return .invalid_amount;

    if (!attachment.returnGraphicsCredit(bytes)) {
        return .invalid_amount;
    }

    return .returned;
}

/// Accepts only the frame currently outstanding for the selected client
/// attachment. A null result leaves every synchronization baseline intact.
///
/// ```zig
/// const elapsed = store.acknowledgeFrame(ack, received_at_ns) orelse return;
/// ```
pub fn acknowledgeFrame(store: *AttachmentStore, ack: FrameAckType, received_at_ns: u64) ?u64 {
    const attachment = store.find(ack.pane_id) orelse return null;
    return attachment.acknowledgeFrame(ack.frame_id, received_at_ns);
}

/// Applies a bounded viewport offset to one client attachment. Missing
/// panes return null; allocation failure preserves the previous projection.
///
/// ```zig
/// const update = try store.setPaneViewport(viewport) orelse return;
/// ```
pub fn setPaneViewport(store: *AttachmentStore, viewport: SetPaneViewportType) !?attachment_namespace.ViewportUpdate {
    const attachment = store.find(viewport.pane_id) orelse return null;
    const changed = try attachment.setViewport(viewport.offset);
    return if (changed) .changed else .unchanged;
}

/// Reads one attached pane's inclusive scrollback range into caller-owned
/// fixed storage. The returned bytes borrow `scratch`; a missing pane is
/// distinguished from an empty or unavailable selection.
///
/// ```zig
/// const result = store.copySelection(pane_id, .{
///     .range = range,
///     .scratch = &scratch,
/// }) orelse return;
/// ```
pub fn copySelection(store: *AttachmentStore, pane_id: PaneIdType, query: SelectionQuery) ?selection.Result {
    const attachment = store.find(pane_id) orelse return null;
    return attachment.copySelection(query.range, query.scratch);
}

pub fn at(store: *AttachmentStore, index: usize) ?*Attachment {
    if (index >= store.items.len) {
        return null;
    }
    return if (store.items[index]) |*attachment| attachment else null;
}

pub fn iterator(store: *const AttachmentStore) IteratorType {
    return .{ .store = store };
}

pub fn len(store: *const AttachmentStore) usize {
    return store.count;
}

pub fn currentWorkspace(store: *const AttachmentStore) ?WorkspaceLocationType {
    return store.workspace;
}

/// Changes the transport policy for existing and future attachments as one
/// aggregate update. Repeating the active policy leaves every item intact.
///
/// ```zig
/// const update = store.configureGraphics(true);
/// ```
pub fn configureGraphics(store: *AttachmentStore, shared: bool) attachment_namespace.GraphicsConfigurationUpdate {
    if (store.shared_graphics == shared) {
        return .unchanged;
    }

    store.shared_graphics = shared;
    for (&store.items) |*slot| {
        const attachment = if (slot.*) |*value| value else continue;
        attachment.configureGraphics(shared);
    }

    return .changed;
}

pub fn attach(store: *AttachmentStore, gpa: std.mem.Allocator, pane: *PaneType) !*Attachment {
    std.debug.assert(pane.launch_state == .running);
    if (store.find(pane.id)) |existing| {
        return existing;
    }
    if (store.workspace) |workspace| {
        if (!std.meta.eql(workspace, pane.location.workspace)) {
            return error.WorkspaceMismatch;
        }
    }
    if (store.count == max_panes_per_tab) {
        return error.AttachmentLimitReached;
    }
    for (&store.items, 0..) |*slot, position| {
        if (slot.* == null) {
            slot.* = try Attachment.init(gpa, pane);
            slot.*.?.configureGraphics(store.shared_graphics);
            store.index.put(raw_module(pane.id), position);
            if (store.workspace == null) {
                store.workspace = pane.location.workspace;
            }
            store.count += 1;
            return &slot.*.?;
        }
    }
    unreachable;
}

/// Removes one attachment while retaining workspace observation. The
/// caller may need that observation to publish lifecycle events before
/// completing departure with `leaveWorkspace`.
///
/// ```zig
/// const detached = store.detach(pane_id) orelse return;
/// if (detached.last_attachment) {
///     _ = store.leaveWorkspace(detached.workspace);
/// }
/// ```
pub fn detach(store: *AttachmentStore, pane_id: PaneIdType) ?PaneDetached {
    const position = store.index.get(raw_module(pane_id)) orelse return null;
    const attachment = &store.items[position].?;
    std.debug.assert(attachment.pane.id == pane_id);
    const workspace = attachment.pane.location.workspace;
    std.debug.assert(store.workspace != null and std.meta.eql(store.workspace.?, workspace));

    attachment.deinit();
    store.index.remove(raw_module(pane_id));
    store.items[position] = null;
    store.count -= 1;

    return .{
        .pane_id = pane_id,
        .workspace = workspace,
        .last_attachment = store.count == 0,
    };
}

/// Ends observation of an empty workspace after any lifecycle event that
/// depended on it has been published. A mismatched or non-empty store is
/// left unchanged.
///
/// ```zig
/// if (store.leaveWorkspace(workspace)) {
///     release(workspace);
/// }
/// ```
pub fn leaveWorkspace(store: *AttachmentStore, workspace: WorkspaceLocationType) bool {
    if (store.count != 0 or store.workspace == null or !std.meta.eql(store.workspace.?, workspace)) {
        return false;
    }

    store.workspace = null;
    return true;
}

pub fn observes(store: *const AttachmentStore, workspace: WorkspaceLocationType) bool {
    return store.workspace != null and std.meta.eql(store.workspace.?, workspace);
}

pub fn availableGraphicsCredit(store: *const AttachmentStore) usize {
    var outstanding: usize = 0;
    for (store.items) |slot| {
        const attachment = slot orelse continue;
        outstanding +|= max_image_bytes_per_pane_module -
            @min(attachment.graphicsCredit(), max_image_bytes_per_pane_module);
    }
    return max_image_bytes_global_module -|
        @min(outstanding, max_image_bytes_global_module);
}

/// Releases every attachment while preserving per-client configuration for
/// the next workspace view.
///
/// ```zig
/// store.clearAttachments();
/// ```
pub fn clearAttachments(store: *AttachmentStore) void {
    for (&store.items) |*slot| {
        if (slot.*) |*attachment| {
            attachment.deinit();
        }
        slot.* = null;
    }
    store.index.reset();
    store.count = 0;
    store.workspace = null;
}

pub fn deinit(store: *AttachmentStore) void {
    store.clearAttachments();
    store.shared_graphics = false;
}
