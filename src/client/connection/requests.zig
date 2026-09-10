//! Typed continuations for requests sent by the disposable client.
//!
//! The client registers a request and its outbound message as one operation.
//! Exactly one success or failure consumes the continuation. Lifecycle events
//! may turn it into `.ignored` when the runtime already made the result stale.

const std = @import("std");
const core = @import("telar-core");
const layout = @import("../workspace/root.zig").layout;

const schema = core.schema;
const ui = core.ui;

pub const Split = struct {
    target_pane: schema.PaneId,
    location: schema.TabLocation,
    axis: layout.Axis,
    area: ui.Rect,
};

pub const PaneOperation = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const InitialOpen = struct {
    /// Retried when a remembered pane disappeared while its workspace was
    /// inactive. Null for process bootstrap and non-workspace targets.
    fallback_workspace: ?schema.WorkspaceId = null,
};

pub const CreateTab = struct {
    workspace: schema.WorkspaceLocation,
    size: schema.TerminalSize,
};

pub const Continuation = union(enum) {
    initial_open: InitialOpen,
    create_workspace: schema.TerminalSize,
    rename_workspace: schema.WorkspaceLocation,
    workspace_snapshot: schema.WorkspaceLocation,
    tab_snapshot: schema.TabLocation,
    split: Split,
    close_pane: PaneOperation,
    attach_pane: PaneOperation,
    create_tab: CreateTab,
    rename_tab: schema.TabLocation,
    close_tab: schema.TabLocation,
    move_tab: schema.TabLocation,
    notification,
    ignored,

    fn group(continuation: Continuation) Group {
        return switch (continuation) {
            .initial_open => .initial_open,
            .create_workspace, .rename_workspace => .workspace_operation,
            .workspace_snapshot => .workspace_snapshot,
            .tab_snapshot => .tab_snapshot,
            .split, .close_pane => .pane_operation,
            .attach_pane => .attachment,
            .create_tab, .rename_tab, .close_tab, .move_tab => .tab_operation,
            .notification => .notification,
            .ignored => .ignored,
        };
    }

    fn tabId(continuation: Continuation) ?schema.TabId {
        return switch (continuation) {
            .tab_snapshot => |location| location.tab_id,
            .split => |split| split.location.tab_id,
            .close_pane, .attach_pane => |operation| operation.location.tab_id,
            .rename_tab, .close_tab, .move_tab => |location| location.tab_id,
            .initial_open, .create_workspace, .rename_workspace, .workspace_snapshot, .create_tab, .notification, .ignored => null,
        };
    }

    fn paneId(continuation: Continuation) ?schema.PaneId {
        return switch (continuation) {
            .split => |split| split.target_pane,
            .close_pane, .attach_pane => |operation| operation.pane_id,
            .initial_open, .create_workspace, .rename_workspace, .workspace_snapshot, .tab_snapshot, .create_tab, .rename_tab, .close_tab, .move_tab, .notification, .ignored => null,
        };
    }
};

pub const Group = enum {
    initial_open,
    workspace_operation,
    workspace_snapshot,
    tab_snapshot,
    pane_operation,
    attachment,
    tab_operation,
    notification,
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

    /// Retains one unique typed continuation in fixed storage.
    ///
    /// ```zig
    /// try tracker.add(request_id, continuation);
    /// ```
    pub fn add(tracker: *Tracker, request_id: schema.RequestId, continuation: Continuation) !void {
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
    pub fn has(tracker: *const Tracker, group: Group) bool {
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
    pub fn hasPane(tracker: *const Tracker, group: Group, pane_id: schema.PaneId) bool {
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
    pub fn take(tracker: *Tracker, request_id: schema.RequestId) ?Continuation {
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
    pub fn ignoreTab(tracker: *Tracker, tab_id: schema.TabId) void {
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
    pub fn ignorePane(tracker: *Tracker, pane_id: schema.PaneId) void {
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
    pub fn ignoreAttachment(tracker: *Tracker, pane_id: schema.PaneId) bool {
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

test "pane reconciliation finds attachments and retires pane operations" {
    var tracker: Tracker = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: schema.PaneId = @enumFromInt(3);
    try tracker.add(@enumFromInt(7), .{ .attach_pane = .{
        .pane_id = pane_id,
        .location = location,
    } });
    try tracker.add(@enumFromInt(8), .{ .close_pane = .{
        .pane_id = pane_id,
        .location = location,
    } });

    try std.testing.expect(tracker.hasPane(.attachment, pane_id));
    try std.testing.expect(tracker.hasPane(.pane_operation, pane_id));
    tracker.ignorePane(pane_id);

    try std.testing.expect(!tracker.hasPane(.attachment, pane_id));
    try std.testing.expect(!tracker.hasPane(.pane_operation, pane_id));
    try std.testing.expect(tracker.take(@enumFromInt(7)).? == .ignored);
    try std.testing.expect(tracker.take(@enumFromInt(8)).? == .ignored);
}

test "tab detachment retires only the matching pane attachment" {
    var tracker: Tracker = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: schema.PaneId = @enumFromInt(3);
    try tracker.add(@enumFromInt(7), .{ .attach_pane = .{
        .pane_id = pane_id,
        .location = location,
    } });
    try tracker.add(@enumFromInt(8), .{ .close_pane = .{
        .pane_id = pane_id,
        .location = location,
    } });

    try std.testing.expect(tracker.ignoreAttachment(pane_id));
    try std.testing.expect(!tracker.hasPane(.attachment, pane_id));
    try std.testing.expect(tracker.hasPane(.pane_operation, pane_id));
    try std.testing.expect(tracker.take(@enumFromInt(7)).? == .ignored);
    try std.testing.expect(tracker.take(@enumFromInt(8)).? == .close_pane);
    try std.testing.expect(!tracker.ignoreAttachment(pane_id));
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

test "split correlation survives target and tab retirement" {
    var tracker: Tracker = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: schema.PaneId = @enumFromInt(3);
    try tracker.add(@enumFromInt(7), .{ .split = .{
        .target_pane = pane_id,
        .location = location,
        .axis = .horizontal,
        .area = .{ .w = 40, .h = 10 },
    } });

    tracker.ignorePane(pane_id);
    tracker.ignoreTab(location.tab_id);

    const continuation = tracker.take(@enumFromInt(7)).?;
    try std.testing.expect(continuation == .split);
    try std.testing.expectEqualDeep(location, continuation.split.location);
    try std.testing.expectEqual(pane_id, continuation.split.target_pane);
}
