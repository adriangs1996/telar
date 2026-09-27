//! Typed continuations for requests sent by the disposable client.
//!
//! The client registers a request and its outbound message as one operation.
//! Exactly one success or failure consumes the continuation. Lifecycle events
//! may turn it into `.ignored` when the runtime already made the result stale.

const core = @import("telar-core");
const Tracker = @import("Tracker.zig");
const std = @import("std");

pub const Continuation = @import("RequestsContinuation.zig").RequestsContinuation;

pub const Group = @import("RequestsGroup.zig").RequestsGroup;

test "request success consumes its typed continuation once" {
    var tracker: Tracker = .{};
    const request_id: core.RequestId = @enumFromInt(7);
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(
        request_id,
        .{
            .attach_pane = .{
                .pane_id = @enumFromInt(3),
                .location = location,
            },
        },
    );

    const continuation = tracker.take(request_id).?;
    try std.testing.expect(continuation == .attach_pane);
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(3)), continuation.attach_pane.pane_id);
    try std.testing.expect(tracker.take(request_id) == null);
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}

test "tab lifecycle makes every related continuation explicitly ignored" {
    var tracker: Tracker = .{};
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(
        @enumFromInt(7),
        .{
            .tab_snapshot = location,
        },
    );
    try tracker.add(
        @enumFromInt(8),
        .{
            .attach_pane = .{
                .pane_id = @enumFromInt(3),
                .location = location,
            },
        },
    );

    tracker.ignoreTab(location.tab_id);

    try std.testing.expect(tracker.take(@enumFromInt(7)).? == .ignored);
    try std.testing.expect(tracker.take(@enumFromInt(8)).? == .ignored);
}

test "pane reconciliation finds attachments and retires pane operations" {
    var tracker: Tracker = .{};
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: core.PaneId = @enumFromInt(3);
    try tracker.add(
        @enumFromInt(7),
        .{
            .attach_pane = .{
                .pane_id = pane_id,
                .location = location,
            },
        },
    );
    try tracker.add(
        @enumFromInt(8),
        .{
            .close_pane = .{
                .pane_id = pane_id,
                .location = location,
            },
        },
    );

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
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: core.PaneId = @enumFromInt(3);
    try tracker.add(
        @enumFromInt(7),
        .{
            .attach_pane = .{
                .pane_id = pane_id,
                .location = location,
            },
        },
    );
    try tracker.add(
        @enumFromInt(8),
        .{
            .close_pane = .{
                .pane_id = pane_id,
                .location = location,
            },
        },
    );

    try std.testing.expect(tracker.ignoreAttachment(pane_id));
    try std.testing.expect(!tracker.hasPane(.attachment, pane_id));
    try std.testing.expect(tracker.hasPane(.pane_operation, pane_id));
    try std.testing.expect(tracker.take(@enumFromInt(7)).? == .ignored);
    try std.testing.expect(tracker.take(@enumFromInt(8)).? == .close_pane);
    try std.testing.expect(!tracker.ignoreAttachment(pane_id));
}

test "pane exit completes only its matching close request" {
    var tracker: Tracker = .{};
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    try tracker.add(
        @enumFromInt(7),
        .{
            .close_pane = .{
                .pane_id = @enumFromInt(3),
                .location = location,
            },
        },
    );

    try std.testing.expect(!tracker.completePaneClose(@enumFromInt(4)));
    try std.testing.expect(tracker.completePaneClose(@enumFromInt(3)));
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
}

test "split correlation survives target and tab retirement" {
    var tracker: Tracker = .{};
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };
    const pane_id: core.PaneId = @enumFromInt(3);
    try tracker.add(
        @enumFromInt(7),
        .{
            .split = .{
                .target_pane = pane_id,
                .location = location,
                .axis = .horizontal,
                .area = .{
                    .w = 40,
                    .h = 10,
                },
            },
        },
    );

    tracker.ignorePane(pane_id);
    tracker.ignoreTab(location.tab_id);

    const continuation = tracker.take(@enumFromInt(7)).?;
    try std.testing.expect(continuation == .split);
    try std.testing.expectEqualDeep(location, continuation.split.location);
    try std.testing.expectEqual(pane_id, continuation.split.target_pane);
}

test "group queries over live entries answer as a scan of every entry would" {
    var random: std.Random.DefaultPrng = .init(@intFromEnum(Oracle.seed));
    var tracker: Tracker = .{};
    for (0..@intFromEnum(Oracle.operations)) |_| {
        const pane_id: core.PaneId = @enumFromInt(random.random().uintLessThan(u64, @intFromEnum(Oracle.panes)) + 1);
        const tab_id: core.TabId = @enumFromInt(random.random().uintLessThan(u64, @intFromEnum(Oracle.tabs)) + 1);
        const request_id: core.RequestId = @enumFromInt(random.random().uintLessThan(u64, @intFromEnum(Oracle.request_ids)) + 1);
        switch (random.random().uintLessThan(u8, @intFromEnum(Oracle.operation_kinds))) {
            0, 1, 2 => tracker.add(request_id, oracleContinuation(random.random(), pane_id, tab_id)) catch {},
            3 => _ = tracker.take(request_id),
            4 => tracker.ignoreTab(tab_id),
            5 => tracker.ignorePane(pane_id),
            6 => _ = tracker.ignoreAttachment(pane_id),
            else => _ = tracker.completePaneClose(pane_id),
        }

        for (std.enums.values(Group)) |group| {
            try std.testing.expectEqual(scanHas(&tracker, group), tracker.has(group));
            for (1..@intFromEnum(Oracle.panes) + 1) |pane| {
                const id: core.PaneId = @enumFromInt(pane);
                try std.testing.expectEqual(scanHasPane(&tracker, group, id), tracker.hasPane(group, id));
            }
        }
    }
}

const Oracle = enum(u64) {
    seed = 0x7e1a,
    operations = 4000,
    panes = 5,
    tabs = 3,
    request_ids = 96,
    operation_kinds = 8,
};

fn oracleContinuation(random: std.Random, pane_id: core.PaneId, tab_id: core.TabId) Continuation {
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = tab_id,
    };
    const operation: @FieldType(Continuation, "attach_pane") = .{
        .pane_id = pane_id,
        .location = location,
    };

    return switch (random.uintLessThan(u8, 6)) {
        0 => .{ .attach_pane = operation },
        1 => .{ .close_pane = operation },
        2 => .{ .tab_snapshot = location },
        3 => .{ .rename_tab = location },
        4 => .{
            .split = .{
                .target_pane = pane_id,
                .location = location,
                .axis = .horizontal,
                .area = .{},
            },
        },
        else => .notification,
    };
}

/// The query as it was before it visited only live entries: a copy of every entry.
fn scanHas(tracker: *const Tracker, group: Group) bool {
    for (tracker.entries) |slot| {
        const entry = slot orelse continue;
        if (entry.continuation.group() == group) {
            return true;
        }
    }

    return false;
}

fn scanHasPane(tracker: *const Tracker, group: Group, pane_id: core.PaneId) bool {
    for (tracker.entries) |slot| {
        const entry = slot orelse continue;
        if (entry.continuation.group() == group and entry.continuation.paneId() == pane_id) {
            return true;
        }
    }

    return false;
}
