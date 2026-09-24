//! Actor ownership and recovery through production event dispatch.
const agent_status = @import("../agent_status.zig");
const pane_graphics = @import("../pane_graphics.zig");
const pane_observation = @import("../pane_observation.zig");
const std = @import("std");
const pane_input = @import("../pane_input.zig");
const core = @import("telar-core");
const EventFixture = @import("EventFixture.zig");
const event = @import("../event.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const agent_identity = @import("../agent_identity.zig");

const WriteKind = enum { input, response };

test "runtime PTY scheduling preserves queued bytes when actor admission fails" {
    for (std.enums.values(WriteKind)) |kind| {
        var fixture: EventFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.failScheduling();
        const pane = fixture.pane;
        switch (kind) {
            .input => {
                try pane_input.startInputWrite(fixture.model, pane);
                try std.testing.expect(pane.queuePtyInput("queued"));
                try std.testing.expectError(error.ConcurrencyUnavailable, pane_input.startInputWrite(fixture.model, pane));
                try std.testing.expectEqualStrings("queued", pane.input_queue.nextChunk().?);
                try std.testing.expect(!pane.input_write_pending);
                try std.testing.expectEqual(@as(usize, 0), pane.input_write_len);
            },
            .response => {
                try pane_input.startResponseWrite(fixture.model, pane);
                try std.testing.expect(pane.pty_responses.push("queued"));
                try std.testing.expectError(error.ConcurrencyUnavailable, pane_input.startResponseWrite(fixture.model, pane));
                try std.testing.expectEqualStrings("queued", pane.pty_responses.peek().?);
                try std.testing.expect(!pane.response_pending);
            },
        }
        try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    }
}

test "runtime successful PTY completion releases its prefix before failed backlog admission" {
    for (std.enums.values(WriteKind)) |kind| {
        var fixture: EventFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.failScheduling();
        const pane = fixture.pane;
        const completion: event.Event = switch (kind) {
            .input => value: {
                try std.testing.expect(pane.queuePtyInput("first"));
                _ = pane.beginPtyInputWrite().?;
                try std.testing.expect(pane.queuePtyInput("second"));
                break :value .{ .pane_input_written = .{ .pane = pane.key(), .started_ns = core.now(std.testing.io), .result = {} } };
            },
            .response => value: {
                try std.testing.expect(pane.pty_responses.push("first"));
                _ = pane.beginPtyResponseWrite().?;
                try std.testing.expect(pane.pty_responses.push("second"));
                break :value .{ .pane_response_written = .{ .pane = pane.key(), .result = {} } };
            },
        };
        try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(completion));
        const queued = switch (kind) {
            .input => pane.input_queue.nextChunk(),
            .response => pane.pty_responses.peek(),
        };
        try std.testing.expectEqualStrings("second", queued.?);
        try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
        try std.testing.expect(!pane.input_write_pending and !pane.response_pending);
    }
}

test "runtime failed PTY response completion discards queued responses and releases its borrow" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    try std.testing.expect(pane.pty_responses.push("first"));
    _ = pane.beginPtyResponseWrite().?;
    try std.testing.expect(pane.pty_responses.push("second"));
    _ = try fixture.request.runtime.update(.{ .pane_response_written = .{ .pane = pane.key(), .result = error.BrokenPipe } });
    try std.testing.expect(pane.pty_responses.peek() == null);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "runtime observation and media admission roll back sealed actor borrows" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const pane = fixture.pane;
    pane.queueHistoryOutput(.{ .bytes = "history", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expectError(error.ConcurrencyUnavailable, pane_observation.start(fixture.model, pane));
    try std.testing.expect(pane.history_observer.worker == null);
    try std.testing.expect(!pane.history_observer.hasPending());
    pane.queueMediaOutput("media");
    try std.testing.expectError(error.ConcurrencyUnavailable, pane_graphics.startMedia(fixture.model, pane));
    try std.testing.expect(pane.media.worker == null);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "runtime stale projection and ingest completions retain live actor borrows" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    try fixture.beginObservation();
    defer pane.cancelHistoryObservation();
    pane.queueMediaOutput("media");
    _ = pane.beginMediaProcessing().?;
    defer pane.cancelMediaProcessing();
    _ = pane.beginOutputIngest(1);
    defer pane.cancelOutputIngest();
    var stale = pane.key();
    stale.generation += 1;
    const completions = [_]event.Event{
        .{ .pane_observed = .{ .pane = stale, .stats = .{}, .process_probe = .{ .cache = .{} } } },
        .{ .pane_media = .{ .pane = stale, .stats = .{} } },
        .{ .pane_ingested = .{ .pane = stale, .result = error.IngestFailed } },
    };
    for (completions) |completion| {
        _ = try fixture.request.runtime.update(completion);
    }
    try std.testing.expectEqual(@as(u8, 3), pane.actor_count);
    try std.testing.expect(pane.history_observer.worker != null and pane.media.worker != null and pane.ingest_pending);
    try std.testing.expectEqual(@as(u64, 3), fixture.metrics.stale_pane_events);
}

test "runtime ingest failure releases the output buffer and retires its PTY output" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    _ = pane.beginOutputIngest(1);
    _ = try fixture.request.runtime.update(.{ .pane_ingested = .{ .pane = pane.key(), .result = error.IngestFailed } });
    try std.testing.expect(pane.close_requested and pane.output_done);
    try std.testing.expect(!pane.ingest_pending and !pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.ingest.count);
}

test "runtime ingest commits a deferred resize before failed next-read admission" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const pane = fixture.pane;
    _ = pane.beginOutputIngest(1);
    const size: core.TerminalSize = .{ .cols = 31, .rows = 9 };
    try pane.requestResize(size);
    try std.testing.expect(pane.pending_size != null);
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .pane_ingested = .{ .pane = pane.key(), .result = .{ .elapsed_ns = 37 } } }));
    try std.testing.expectEqualDeep(size, pane.size);
    try std.testing.expect(pane.pending_size == null);
    try std.testing.expect(!pane.ingest_pending and !pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try std.testing.expectEqual(if (core.enabled) @as(u64, 37) else 0, fixture.metrics.ingest.total_ns);
}

test "runtime PTY read failure finishes output without borrowing ingest storage" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    try std.testing.expect(pane.beginPtyOutputRead());
    _ = try fixture.request.runtime.update(.{ .pane_output = .{ .pane = pane.key(), .result = error.ReadFailed } });
    try std.testing.expect(pane.output_done);
    try std.testing.expect(!pane.output_pending and !pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "runtime PTY data releases its read before observation admission can fail" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const pane = fixture.pane;
    try std.testing.expect(pane.beginPtyOutputRead());
    @memcpy(pane.output_buffer[0..4], "text");
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .pane_output = .{ .pane = pane.key(), .result = 4 } }));
    try std.testing.expect(!pane.output_pending and !pane.ingest_pending);
    try std.testing.expect(pane.history_observer.worker == null and pane.media.worker == null);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "runtime child exit retires agent evidence and releases its wait borrow" {
    for ([_]bool{ false, true }) |failed| {
        var fixture: EventFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const pane = fixture.pane;
        try std.testing.expect(pane.beginExitWait());
        _ = agent_status.observeProcess(fixture.model, .{ .identity = agent_identity.fromPane(pane), .provider = .codex, .process_id = 27, .observed_at_ms = 1 });
        _ = try fixture.request.runtime.update(.{ .pane_exit = .{ .pane = pane.key(), .result = if (failed) error.WaitFailed else .{ .exited = 7 } } });
        try std.testing.expect(pane.exit != null);
        if (failed) {
            try std.testing.expectEqual(.KILL, pane.exit.?.signaled);
        } else {
            try std.testing.expectEqual(@as(u8, 7), pane.exit.?.exited);
        }
        try std.testing.expect(!pane.wait_pending);
        try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.model.panes.exited_count);
        try std.testing.expect(agent_status.projectedStatus(fixture.model, pane.key()) == null);
    }
}

test "runtime drained exit preserves retirement when final observation cannot start" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const pane = fixture.pane;
    pane.finishPtyOutput();
    try std.testing.expect(pane.beginExitWait());
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .pane_exit = .{ .pane = pane.key(), .result = .{ .exited = 0 } } }));
    try std.testing.expect(pane.exit != null and pane.history_exit_queued);
    try std.testing.expect(!pane.wait_pending and pane.history_observer.worker == null);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "runtime media completion releases its actor before publishing bounded metrics" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    pane.queueMediaOutput("media");
    _ = pane.beginMediaProcessing().?;
    _ = try fixture.request.runtime.update(.{ .pane_media = .{
        .pane = pane.key(),
        .stats = .{ .output_bytes = 13, .discarded_frames = 2, .unavailable_frames = 3, .forwarded_frames = 5, .failed = true, .reset = true },
    } });
    try std.testing.expect(pane.media.worker == null);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try std.testing.expectEqual(if (core.enabled) @as(u64, 13) else 0, fixture.metrics.media_bytes);
    try std.testing.expectEqual(if (core.enabled) @as(u64, 1) else 0, fixture.metrics.media_resets);
}

test {
    _ = @import("observation_events_test.zig");
    _ = @import("agent_events_test.zig");
    _ = @import("observability_events_test.zig");
}
