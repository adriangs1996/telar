//! Typed continuations for requests sent by the disposable client.
//!
//! The client registers a request and its outbound message as one operation.
//! Exactly one success or failure consumes the continuation. Lifecycle events
//! may turn it into `.ignored` when the runtime already made the result stale.

const InitialOpen = @import("InitialOpen.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const Split = @import("Split.zig");
const PaneOperation = @import("PaneOperation.zig");
const CreateTab = @import("CreateTab.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const Tracker = @import("Tracker.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");

pub const Continuation = union(enum) {
    initial_open: InitialOpen,
    create_workspace: TerminalSizeType,
    rename_workspace: WorkspaceLocationType,
    workspace_snapshot: WorkspaceLocationType,
    tab_snapshot: TabLocationType,
    split: Split,
    close_pane: PaneOperation,
    attach_pane: PaneOperation,
    create_tab: CreateTab,
    rename_tab: TabLocationType,
    close_tab: TabLocationType,
    move_tab: TabLocationType,
    notification,
    ignored,

    pub fn group(continuation: Continuation) Group {
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

    pub fn tabId(continuation: Continuation) ?TabIdType {
        return switch (continuation) {
            .tab_snapshot => |location| location.tab_id,
            .split => |split| split.location.tab_id,
            .close_pane, .attach_pane => |operation| operation.location.tab_id,
            .rename_tab, .close_tab, .move_tab => |location| location.tab_id,
            .initial_open, .create_workspace, .rename_workspace, .workspace_snapshot, .create_tab, .notification, .ignored => null,
        };
    }

    pub fn paneId(continuation: Continuation) ?PaneIdType {
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

test "request success consumes its typed continuation once" {
    var tracker: Tracker = .{};
    const request_id: RequestIdType = @enumFromInt(7);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(request_id, .{ .attach_pane = .{
        .pane_id = @enumFromInt(3),
        .location = location,
    } });

    const continuation = tracker.take(request_id).?;
    try std.testing.expect(continuation == .attach_pane);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(3)), continuation.attach_pane.pane_id);
    try std.testing.expect(tracker.take(request_id) == null);
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}

test "tab lifecycle makes every related continuation explicitly ignored" {
    var tracker: Tracker = .{};
    const location: TabLocationType = .{
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
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: PaneIdType = @enumFromInt(3);
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
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: PaneIdType = @enumFromInt(3);
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
    const location: TabLocationType = .{
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
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: PaneIdType = @enumFromInt(3);
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
