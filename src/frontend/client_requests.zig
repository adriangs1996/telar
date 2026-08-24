//! Typed continuations for requests sent by the disposable client.
//!
//! The client registers a request and its outbound message as one operation.
//! Exactly one success or failure consumes the continuation. Lifecycle events
//! may turn it into `.ignored` when the runtime already made the result stale.

const std = @import("std");
const core = @import("telar-core");
const layout = @import("layout.zig");

const schema = core.schema;

pub const Split = struct {
    target_pane: schema.PaneId,
    location: schema.TabLocation,
    axis: layout.Axis,
};

pub const PaneOperation = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const Continuation = union(enum) {
    initial_open,
    workspace_snapshot: schema.WorkspaceLocation,
    tab_snapshot: schema.TabLocation,
    split: Split,
    close_pane: PaneOperation,
    attach_pane: PaneOperation,
    create_tab: schema.WorkspaceLocation,
    rename_tab: schema.TabLocation,
    close_tab: schema.TabLocation,
    move_tab: schema.TabLocation,
    ignored,

    fn group(continuation: Continuation) Group {
        return switch (continuation) {
            .initial_open => .initial_open,
            .workspace_snapshot => .workspace_snapshot,
            .tab_snapshot => .tab_snapshot,
            .split, .close_pane => .pane_operation,
            .attach_pane => .attachment,
            .create_tab, .rename_tab, .close_tab, .move_tab => .tab_operation,
            .ignored => .ignored,
        };
    }

    fn tabId(continuation: Continuation) ?schema.TabId {
        return switch (continuation) {
            .tab_snapshot => |location| location.tab_id,
            .split => |split| split.location.tab_id,
            .close_pane, .attach_pane => |operation| operation.location.tab_id,
            .rename_tab, .close_tab, .move_tab => |location| location.tab_id,
            .initial_open, .workspace_snapshot, .create_tab, .ignored => null,
        };
    }
};

pub const Group = enum {
    initial_open,
    workspace_snapshot,
    tab_snapshot,
    pane_operation,
    attachment,
    tab_operation,
    ignored,
};

pub const Entry = struct {
    request_id: schema.RequestId,
    continuation: Continuation,
};

pub const Tracker = struct {
    /// One attachment per pane plus the singleton client operations.
    pub const capacity = schema.max_panes_per_tab + 8;

    entries: [capacity]?Entry = @splat(null),
    count: usize = 0,

    pub fn add(
        tracker: *Tracker,
        request_id: schema.RequestId,
        continuation: Continuation,
    ) !void {
        std.debug.assert(request_id != .none);
        for (&tracker.entries) |*slot| {
            if (slot.*) |entry| {
                if (entry.request_id == request_id) return error.DuplicateRequest;
                continue;
            }
            slot.* = .{ .request_id = request_id, .continuation = continuation };
            tracker.count += 1;
            return;
        }
        return error.TooManyPendingRequests;
    }

    pub fn has(tracker: *const Tracker, group: Group) bool {
        for (tracker.entries) |slot| {
            const entry = slot orelse continue;
            if (entry.continuation.group() == group) return true;
        }
        return false;
    }

    pub fn take(tracker: *Tracker, request_id: schema.RequestId) ?Continuation {
        for (&tracker.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.request_id != request_id) continue;
            slot.* = null;
            tracker.count -= 1;
            return entry.continuation;
        }
        return null;
    }

    /// A tab lifecycle notification is authoritative. Requests already sent
    /// for that tab remain identifiable, but their eventual failures need no
    /// rollback because the tab and its client state are already gone.
    pub fn ignoreTab(tracker: *Tracker, tab_id: schema.TabId) void {
        for (&tracker.entries) |*slot| {
            const entry = if (slot.*) |*value| value else continue;
            if (entry.continuation.tabId() == tab_id)
                entry.continuation = .ignored;
        }
    }

    /// Pane exit is the successful completion signal for `close_pane`.
    pub fn completePaneClose(tracker: *Tracker, pane_id: schema.PaneId) bool {
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
};

test "request success consumes its typed continuation once" {
    var tracker: Tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(7);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(request_id, .{ .attach_pane = .{
        .pane_id = @enumFromInt(3),
        .location = location,
    } });

    const continuation = tracker.take(request_id).?;
    try std.testing.expect(continuation == .attach_pane);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(3)), continuation.attach_pane.pane_id);
    try std.testing.expect(tracker.take(request_id) == null);
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}

test "tab lifecycle makes every related continuation explicitly ignored" {
    var tracker: Tracker = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(@enumFromInt(7), .{ .tab_snapshot = location });
    try tracker.add(@enumFromInt(8), .{ .attach_pane = .{
        .pane_id = @enumFromInt(3),
        .location = location,
    } });

    tracker.ignoreTab(location.tab_id);

    try std.testing.expect(tracker.take(@enumFromInt(7)).? == .ignored);
    try std.testing.expect(tracker.take(@enumFromInt(8)).? == .ignored);
}

test "pane exit completes only its matching close request" {
    var tracker: Tracker = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(@enumFromInt(7), .{ .close_pane = .{
        .pane_id = @enumFromInt(3),
        .location = location,
    } });

    try std.testing.expect(!tracker.completePaneClose(@enumFromInt(4)));
    try std.testing.expect(tracker.completePaneClose(@enumFromInt(3)));
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}
