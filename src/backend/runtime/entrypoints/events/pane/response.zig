//! State machine for asynchronous terminal-emulator responses to a pane PTY.

const GenericResponseRuntimePort = @import("GenericResponseRuntimePort.zig").Type;
const ResponseCapture = @import("ResponseCapture.zig");
const GenericResponsePump = @import("GenericResponsePump.zig").Type;
const Pane = @import("../../../../pane/Pane.zig");
const PaneStore = @import("../../../../pane/PaneStore.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const std = @import("std");

const test_port: GenericResponseRuntimePort(ResponseCapture) = .{
    .start = ResponseCapture.start,
    .collect = ResponseCapture.collect,
};

const TestPump = GenericResponsePump(ResponseCapture, test_port);

fn initTestPane(pane: *Pane) void {
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.pty_responses = .{};
    pane.response_pending = false;
    pane.actor_count = 0;
}

fn testPump(capture: *ResponseCapture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPump {
    return TestPump.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

test "schedule is single-flight and rolls async-start failure back" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ResponseCapture = .{ .start_failure = error.WriterUnavailable };
    var pump = testPump(&capture, &panes, &metrics);

    try pump.schedule(&pane);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expect(pane.pty_responses.push("queued"));
    try std.testing.expectError(error.WriterUnavailable, pump.schedule(&pane));

    try std.testing.expectEqualStrings("queued", pane.pty_responses.peek().?);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);

    capture.start_failure = null;
    try pump.schedule(&pane);
    try pump.schedule(&pane);

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqualStrings("queued", capture.last_bytes);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyResponseWrite();
}

test "successful completion removes one response and starts the next" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ResponseCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .result = {},
    });

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expectEqualStrings("second", capture.last_bytes);
    try std.testing.expectEqualStrings("second", pane.pty_responses.peek().?);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyResponseWrite();
}

test "failed completion clears queued responses without another write" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ResponseCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .result = error.BrokenPipe,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expect(pane.pty_responses.peek() == null);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "next-response start failure preserves the head and skips collection" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ResponseCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));
    capture.start_failure = error.WriterUnavailable;

    try std.testing.expectError(error.WriterUnavailable, pump.complete(.{
        .pane = pane.key(),
        .result = {},
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expectEqualStrings("second", pane.pty_responses.peek().?);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "stale generation cannot release a live response borrow" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ResponseCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("still borrowed"));
    _ = pane.beginPtyResponseWrite().?;

    try pump.complete(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = {},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqualStrings("still borrowed", pane.pty_responses.peek().?);
    pane.cancelPtyResponseWrite();
}
