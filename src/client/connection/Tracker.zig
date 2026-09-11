const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const Entry = @import("Entry.zig");
const RequestIdType = @import("telar-core").RequestId;
const requests = @import("requests.zig");
const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const TabIdType = @import("telar-core").TabId;
const Tracker = @This();

/// One attachment per pane plus the singleton client operations.
pub const capacity = max_panes_per_tab_module + 8;

entries: [capacity]?Entry = @splat(null),
count: usize = 0,

/// Retains one unique typed continuation in fixed storage.
///
/// ```zig
/// try tracker.add(request_id, continuation);
/// ```
pub fn add(tracker: *Tracker, request_id: RequestIdType, continuation: requests.Continuation) !void {
    std.debug.assert(request_id != .none);
    for (&tracker.entries) |*slot| {
        if (slot.*) |entry| {
            if (entry.request_id == request_id) {
                return error.DuplicateRequest;
            }

            continue;
        }

        slot.* = .{ .request_id = request_id, .continuation = continuation };
        tracker.count += 1;

        return;
    }

    return error.TooManyPendingRequests;
}

/// Reports whether another complete correlation can be retained.
///
/// ```zig
/// if (!tracker.hasCapacity()) {
///     return error.TooManyPendingRequests;
/// }
/// ```
pub fn hasCapacity(tracker: *const Tracker) bool {
    return tracker.count < capacity;
}

/// Reports whether no request can still receive a response.
///
/// ```zig
/// if (tracker.isEmpty()) {
///     return;
/// }
/// ```
pub fn isEmpty(tracker: *const Tracker) bool {
    return tracker.count == 0;
}

/// Reports whether any retained continuation belongs to `group`.
///
/// ```zig
/// if (tracker.has(.tab_operation)) {
///     return;
/// }
/// ```
pub fn has(tracker: *const Tracker, group: requests.Group) bool {
    for (tracker.entries) |slot| {
        const entry = slot orelse continue;
        if (entry.continuation.group() == group) {
            return true;
        }
    }

    return false;
}

/// Reports whether one pane already owns a pending request in a group.
///
/// ```zig
/// if (tracker.hasPane(.attachment, pane_id)) {
///     return;
/// }
/// ```
pub fn hasPane(tracker: *const Tracker, group: requests.Group, pane_id: PaneIdType) bool {
    for (tracker.entries) |slot| {
        const entry = slot orelse continue;
        if (entry.continuation.group() == group and entry.continuation.paneId() == pane_id) {
            return true;
        }
    }

    return false;
}

/// Removes and returns one exact correlation at most once.
///
/// ```zig
/// const continuation = tracker.take(request_id) orelse return error.UnexpectedRequest;
/// ```
pub fn take(tracker: *Tracker, request_id: RequestIdType) ?requests.Continuation {
    for (&tracker.entries) |*slot| {
        const entry = slot.* orelse continue;
        if (entry.request_id != request_id) {
            continue;
        }

        slot.* = null;
        tracker.count -= 1;

        return entry.continuation;
    }

    return null;
}

/// A tab lifecycle notification is authoritative. Requests already sent
/// for that tab remain identifiable, but their eventual replies are stale
/// because the tab and its client state are already gone. A split keeps its
/// correlation so a late created pane can still be detached.
///
/// ```zig
/// tracker.ignoreTab(tab_id);
/// ```
pub fn ignoreTab(tracker: *Tracker, tab_id: TabIdType) void {
    for (&tracker.entries) |*slot| {
        const entry = if (slot.*) |*value| value else continue;
        if (entry.continuation.tabId() != tab_id) {
            continue;
        }

        if (entry.continuation != .split) {
            entry.continuation = .ignored;
        }
    }
}

/// Suppresses rollback and notification from late failures after a
/// canonical snapshot retires a pane. A split remains correlated because
/// its success introduces a different pane identity that needs cleanup.
///
/// ```zig
/// tracker.ignorePane(pane_id);
/// ```
pub fn ignorePane(tracker: *Tracker, pane_id: PaneIdType) void {
    for (&tracker.entries) |*slot| {
        const entry = if (slot.*) |*value| value else continue;
        if (entry.continuation.paneId() == pane_id) {
            if (entry.continuation != .split) {
                entry.continuation = .ignored;
            }
        }
    }
}

/// Retires only an in-flight client attachment for a pane. Tab detachment
/// must not suppress an unrelated close or split operation on that pane.
///
/// ```zig
/// _ = tracker.ignoreAttachment(pane_id);
/// ```
pub fn ignoreAttachment(tracker: *Tracker, pane_id: PaneIdType) bool {
    for (&tracker.entries) |*slot| {
        const entry = if (slot.*) |*value| value else continue;
        switch (entry.continuation) {
            .attach_pane => |attachment| {
                if (attachment.pane_id != pane_id) {
                    continue;
                }

                entry.continuation = .ignored;
                return true;
            },
            else => {},
        }
    }

    return false;
}

/// Pane exit is the successful completion signal for `close_pane`.
///
/// ```zig
/// _ = tracker.completePaneClose(pane_id);
/// ```
pub fn completePaneClose(tracker: *Tracker, pane_id: PaneIdType) bool {
    for (&tracker.entries) |*slot| {
        const entry = slot.* orelse continue;
        switch (entry.continuation) {
            .close_pane => |operation| if (operation.pane_id == pane_id) {
                slot.* = null;
                tracker.count -= 1;
                return true;
            },
            else => {},
        }
    }

    return false;
}
