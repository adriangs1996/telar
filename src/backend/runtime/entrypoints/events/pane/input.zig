//! State machine for asynchronous writes from a pane's bounded input queue.

const GenericInputRuntimePort = @import("GenericInputRuntimePort.zig").Type;
const InputCapture = @import("InputCapture.zig");
const GenericInputPump = @import("GenericInputPump.zig").Type;
const Pane = @import("../../../../pane/Pane.zig");
const PaneStore = @import("../../../../pane/PaneStore.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const std = @import("std");
const enabled_module = @import("telar-core").enabled;

const test_port: GenericInputRuntimePort(InputCapture) = .{
    .start = InputCapture.start,
    .collect = InputCapture.collect,
};

const TestPump = GenericInputPump(InputCapture, test_port);

fn initTestPane(pane: *Pane) void {
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.input_queue = .{};
    pane.input_write_pending = false;
    pane.input_write_len = 0;
    pane.actor_count = 0;
}

fn testPump(capture: *InputCapture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPump {
    return TestPump.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn expectInputTiming(metrics: *const RuntimeMetrics, expected_debug_count: u64) !void {
    const expected = if (comptime enabled_module) expected_debug_count else 0;
    try std.testing.expectEqual(expected, metrics.input_write.count);
}

test "schedule is single-flight and rolls async-start failure back" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: InputCapture = .{ .start_failure = error.WriterUnavailable };
    var pump = testPump(&capture, &panes, &metrics);

    try pump.schedule(&pane);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expect(pane.queuePtyInput("queued"));
    try std.testing.expectError(error.WriterUnavailable, pump.schedule(&pane));

    try std.testing.expectEqualStrings("queued", pane.input_queue.nextChunk().?);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(usize, 0), pane.input_write_len);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);

    capture.start_failure = null;
    try pump.schedule(&pane);
    try pump.schedule(&pane);

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqualStrings("queued", capture.last_bytes);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyInputWrite();
}

test "successful completion consumes only its borrow and starts the backlog" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: InputCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = {},
    });

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expectEqualStrings("second", capture.last_bytes);
    try std.testing.expectEqualStrings("second", pane.input_queue.nextChunk().?);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqual(@as(usize, "second".len), pane.input_write_len);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try expectInputTiming(&metrics, 1);
    pane.cancelPtyInputWrite();
}

test "failed completion clears the pump without starting another write" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: InputCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = error.BrokenPipe,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expect(pane.input_queue.nextChunk() == null);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try expectInputTiming(&metrics, 1);
}

test "backlog start failure preserves bytes and skips collection" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: InputCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));
    capture.start_failure = error.WriterUnavailable;

    try std.testing.expectError(error.WriterUnavailable, pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = {},
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expectEqualStrings("second", pane.input_queue.nextChunk().?);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try expectInputTiming(&metrics, 1);
}

test "stale completion is counted without touching writer or lifecycle ports" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: InputCapture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("still borrowed"));
    _ = pane.beginPtyInputWrite().?;

    try pump.complete(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .started_ns = 0,
        .result = {},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try expectInputTiming(&metrics, 0);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqualStrings("still borrowed", pane.input_queue.nextChunk().?);
    pane.cancelPtyInputWrite();
}
