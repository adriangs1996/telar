const core = @import("telar-core");
const Attachment = @import("Attachment.zig");
const std = @import("std");
const attachment_namespace = @import("attachment_namespace.zig");
const Range = @import("Range.zig");
const selection = @import("selection.zig");
const Pane = @import("../../pane/Pane.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const PaneDetached = @import("PaneDetached.zig");
pub const AttachmentStore = @This();

/// One client attaches to at most every pane the runtime holds.
pub const capacity = PaneStore.capacity;
pub const Iterator = @import("Iterator.zig");

items: [capacity]?Attachment = [_]?Attachment{null} ** capacity,
count: usize = 0,
index: core.GenericSlotIndex(2 * capacity) = .{},
workspace: ?core.WorkspaceLocation = null,
shared_graphics: bool = false,
/// The owning client's bit in `Pane.observers`; zero outside a client.
observer: u8 = 0,

/// Finds the next deferred publication that is not waiting for ingest or ACK.
/// Example: `const deadline = attachments.cellDeadline();`.
pub fn cellDeadline(self: *AttachmentStore) ?u64 {
    var earliest: ?u64 = null;
    for (&self.items) |*slot| {
        const attachment = if (slot.*) |*value| value else continue;
        const deadline = attachment.cell_deadline_ns orelse continue;

        if (attachment.pane.ingest_pending or attachment.cells.hasOutstanding()) {
            continue;
        }

        earliest = @min(earliest orelse deadline, deadline);
    }

    return earliest;
}

pub fn find(self: *AttachmentStore, pane_id: core.PaneId) ?*Attachment {
    const slot = self.index.get(core.raw(pane_id)) orelse return null;
    const attachment = &self.items[slot].?;
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
pub fn requestCellSnapshot(self: *AttachmentStore, pane_id: core.PaneId) bool {
    const attachment = self.find(pane_id) orelse return false;
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
pub fn requestGraphicsSnapshot(self: *AttachmentStore, pane_id: core.PaneId) bool {
    const attachment = self.find(pane_id) orelse return false;
    attachment.requestGraphicsSnapshot();
    return true;
}

/// Restores only graphics bytes previously consumed by one client
/// attachment. Invalid amounts and missing panes leave all credit unchanged.
///
/// ```zig
/// const update = store.returnGraphicsCredit(credit);
/// ```
pub fn returnGraphicsCredit(self: *AttachmentStore, credit: core.GraphicsCredit) attachment_namespace.GraphicsCreditUpdate {
    const attachment = self.find(credit.pane_id) orelse return .pane_not_attached;
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
pub fn acknowledgeFrame(self: *AttachmentStore, ack: core.FrameAck, received_at_ns: u64) ?u64 {
    const attachment = self.find(ack.pane_id) orelse return null;
    return attachment.acknowledgeFrame(ack.frame_id, received_at_ns);
}

/// Applies a bounded viewport offset to one client attachment. Missing
/// panes return null; allocation failure preserves the previous projection.
///
/// ```zig
/// const update = try store.setPaneViewport(viewport) orelse return;
/// ```
pub fn setPaneViewport(self: *AttachmentStore, viewport: core.SetPaneViewport) !?attachment_namespace.ViewportUpdate {
    const attachment = self.find(viewport.pane_id) orelse return null;
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
pub fn copySelection(self: *AttachmentStore, pane_id: core.PaneId, query: SelectionQuery) ?selection.Result {
    const attachment = self.find(pane_id) orelse return null;
    return attachment.copySelection(query.range, query.scratch);
}

pub fn at(self: *AttachmentStore, index: usize) ?*Attachment {
    if (index >= self.items.len) {
        return null;
    }
    return if (self.items[index]) |*attachment| attachment else null;
}

pub fn iterator(self: *const AttachmentStore) Iterator {
    return .{ .store = self };
}

pub fn len(self: *const AttachmentStore) usize {
    return self.count;
}

pub fn currentWorkspace(self: *const AttachmentStore) ?core.WorkspaceLocation {
    return self.workspace;
}

/// Changes the transport policy for existing and future attachments as one
/// aggregate update. Repeating the active policy leaves every item intact.
///
/// ```zig
/// const update = store.configureGraphics(true);
/// ```
pub fn configureGraphics(self: *AttachmentStore, shared: bool) attachment_namespace.GraphicsConfigurationUpdate {
    if (self.shared_graphics == shared) {
        return .unchanged;
    }

    self.shared_graphics = shared;
    for (&self.items) |*slot| {
        const attachment = if (slot.*) |*value| value else continue;
        attachment.configureGraphics(shared);
    }

    return .changed;
}

pub fn attach(self: *AttachmentStore, gpa: std.mem.Allocator, pane: *Pane) !*Attachment {
    std.debug.assert(pane.launch_state == .running);
    if (self.find(pane.id)) |existing| {
        return existing;
    }
    if (self.workspace) |workspace| {
        if (!std.meta.eql(workspace, pane.location.workspace)) {
            return error.WorkspaceMismatch;
        }
    }
    if (self.count == capacity) {
        return error.AttachmentLimitReached;
    }
    for (&self.items, 0..) |*slot, position| {
        if (slot.* == null) {
            slot.* = try Attachment.init(gpa, pane);
            slot.*.?.configureGraphics(self.shared_graphics);
            pane.observers |= self.observer;
            self.index.put(core.raw(pane.id), position);
            if (self.workspace == null) {
                self.workspace = pane.location.workspace;
            }
            self.count += 1;
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
pub fn detach(self: *AttachmentStore, pane_id: core.PaneId) ?PaneDetached {
    const position = self.index.get(core.raw(pane_id)) orelse return null;
    const attachment = &self.items[position].?;
    std.debug.assert(attachment.pane.id == pane_id);
    const workspace = attachment.pane.location.workspace;
    std.debug.assert(self.workspace != null and std.meta.eql(self.workspace.?, workspace));

    attachment.pane.observers &= ~self.observer;
    attachment.deinit();
    self.index.remove(core.raw(pane_id));
    self.items[position] = null;
    self.count -= 1;

    return .{
        .pane_id = pane_id,
        .workspace = workspace,
        .last_attachment = self.count == 0,
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
pub fn leaveWorkspace(self: *AttachmentStore, workspace: core.WorkspaceLocation) bool {
    if (self.count != 0 or self.workspace == null or !std.meta.eql(self.workspace.?, workspace)) {
        return false;
    }

    self.workspace = null;
    return true;
}

pub fn observes(self: *const AttachmentStore, workspace: core.WorkspaceLocation) bool {
    return self.workspace != null and std.meta.eql(self.workspace.?, workspace);
}

pub fn availableGraphicsCredit(self: *const AttachmentStore) usize {
    var outstanding: usize = 0;
    for (&self.items) |*slot| {
        const attachment = if (slot.*) |*value| value else continue;
        outstanding +|= core.max_image_bytes_per_pane -
            @min(attachment.graphicsCredit(), core.max_image_bytes_per_pane);
    }
    return core.max_image_bytes_global -|
        @min(outstanding, core.max_image_bytes_global);
}

/// Releases every attachment while preserving per-client configuration for
/// the next workspace view.
///
/// ```zig
/// store.clearAttachments();
/// ```
pub fn clearAttachments(self: *AttachmentStore) void {
    for (&self.items) |*slot| {
        if (slot.*) |*attachment| {
            attachment.pane.observers &= ~self.observer;
            attachment.deinit();
        }
        slot.* = null;
    }
    self.index.reset();
    self.count = 0;
    self.workspace = null;
}

pub fn deinit(self: *AttachmentStore) void {
    self.clearAttachments();
    self.shared_graphics = false;
}

const PaneFixture = @import("../tests/PaneFixture.zig");

test "attachments keep their client's bit in the pane observer mask" {
    const fixture = try std.testing.allocator.create(PaneFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    var first: AttachmentStore = .{ .observer = 0b0010 };
    defer first.deinit();
    var second: AttachmentStore = .{ .observer = 0b1000 };
    defer second.deinit();

    _ = try first.attach(std.testing.allocator, pane);
    _ = try second.attach(std.testing.allocator, pane);
    try std.testing.expectEqual(@as(u8, 0b1010), pane.observers);

    _ = first.detach(pane.id);
    try std.testing.expectEqual(@as(u8, 0b1000), pane.observers);

    second.clearAttachments();
    try std.testing.expectEqual(@as(u8, 0), pane.observers);
}

const SelectionQuery = struct {
    range: Range,
    scratch: []u8,
};
