//! Child output reaches the pane's terminal: one PTY read is split into
//! observation, media and VT ingest work; ingest commits cells and rearms
//! the next read. Folding happens in delivery, never by queueing frames.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Pane = @import("../pane/Pane.zig");
const PaneIngestStats = @import("../pane/PaneIngestStats.zig");
const pane_namespace = @import("../pane/pane_namespace.zig");
const OutputCompletion = @import("entrypoints/events/pane/OutputCompletion.zig");
const IngestCompletion = @import("entrypoints/events/pane/IngestCompletion.zig");
const OutputIngest = @import("entrypoints/events/pane/OutputIngest.zig");
const IngestTestGate = @import("IngestTestGate.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_graphics = @import("pane_graphics.zig");
const pane_input = @import("pane_input.zig");
const pane_launch = @import("pane_launch.zig");
const pane_observation = @import("pane_observation.zig");

/// Takes one PTY read: queues history and media work, then ingests the
/// bytes into the VT inline when they are small or on an actor otherwise.
///
/// ```zig
/// try pane_output.receive(model, completion);
/// ```
pub fn receive(model: *RuntimeModel, completion: OutputCompletion) !void {
    core.mark(model.io, .output_dispatch);
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };
    const output_len = completion.result catch 0;

    if (output_len == 0) {
        pane.completePtyOutputRead(.finished);
        if (pane.exit) |exit| {
            pane.queueExitedHistory(exit);
            try pane_observation.start(model, pane);
        }

        return;
    }

    pane.completePtyOutputRead(.data);

    if (comptime core.enabled) {
        model.metrics.pty_events += 1;
        model.metrics.pty_bytes += output_len;

        if (hasOutstandingFrame(model, pane)) {
            model.metrics.folded_pty_events += 1;
        }
    }

    const bytes = pane.output_buffer[0..output_len];
    const shell_foreground = pane.session.shellForeground();
    pane.expireProgress(shell_foreground orelse false);
    pane.queueHistoryOutput(.{
        .bytes = bytes,
        .shell_foreground = shell_foreground,
        .clock = pane_namespace.historyClock(model.io),
    });
    try pane_observation.start(model, pane);

    pane.queueMediaOutput(bytes);
    try pane_graphics.startMedia(model, pane);

    const ingest: OutputIngest = .{
        .io = model.io,
        .pane = pane,
        .bytes = pane.beginOutputIngest(output_len),
    };
    core.mark(ingest.io, .vt_queued);

    if (model.ingest_gate == null and pane.canInlineOutput(ingest.bytes)) {
        return finishIngest(model, ingestPane(ingest, null));
    }

    model.select.concurrent(.pane_ingested, ingestPane, .{ ingest, model.ingest_gate }) catch |err| {
        pane.cancelOutputIngest();
        return err;
    };
}

/// Commits one ingest: applies a deferred resize, schedules observation,
/// media and terminal responses, refreshes attachments and rearms the read.
///
/// ```zig
/// try pane_output.finishIngest(model, completion);
/// ```
pub fn finishIngest(model: *RuntimeModel, completion: IngestCompletion) !void {
    core.mark(model.io, .ingest_dispatch);
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    pane.completeOutputIngest();
    const stats = completion.result catch {
        _ = pane.requestClose();
        pane.finishPtyOutput();
        return;
    };

    if (comptime core.enabled) {
        model.metrics.ingest.observe(stats.elapsed_ns);
    }

    pane.applyPendingResize() catch {
        _ = pane.requestClose();
    };
    try pane_observation.start(model, pane);
    try pane_graphics.startMedia(model, pane);
    refreshAttachments(model, pane);
    try pane_input.startResponseWrite(model, pane);

    const read_started = pane.beginPtyOutputRead();
    std.debug.assert(read_started);
    model.select.concurrent(.pane_output, pane_launch.readPane, .{ model.io, pane }) catch |err| {
        pane.cancelPtyOutputRead();
        return err;
    };
}

fn hasOutstandingFrame(model: *RuntimeModel, pane: *Pane) bool {
    var observers = pane.observers;
    while (model.clients.nextObserver(&observers)) |client| {
        const attachment = client.attachments.find(pane.id) orelse continue;

        if (attachment.outstandingFrameId() != 0) {
            return true;
        }
    }

    return false;
}

fn refreshAttachments(model: *RuntimeModel, pane: *Pane) void {
    var observers = pane.observers;
    while (model.clients.nextObserver(&observers)) |client| {
        const attachment = client.attachments.find(pane.id) orelse continue;

        _ = attachment.resizeIfNeeded() catch {
            _ = pane_attachment.detachPane(model, client, pane.id);
        };
    }
}

fn ingestPane(ingest: OutputIngest, gate: ?*IngestTestGate) IngestCompletion {
    core.profiling.add(.runtime_ingest, 1);
    core.profiling.add(.runtime_ingest_bytes, ingest.bytes.len);
    const profile_started = core.profiling.start(ingest.io);
    defer core.profiling.finish(ingest.io, .runtime_ingest, profile_started);
    core.mark(ingest.io, .vt_start);
    defer core.mark(ingest.io, .vt_done);

    const path = core.enter(.interactive);
    defer path.restore();

    if (gate) |held| {
        held.wait(ingest.io) catch |err| {
            return .{ .pane = ingest.pane.key(), .result = err };
        };
    }

    var stats: PaneIngestStats = .{};
    stats.elapsed_ns = ingest.pane.ingest(ingest.io, ingest.bytes) catch |err| {
        return .{ .pane = ingest.pane.key(), .result = err };
    };

    return .{ .pane = ingest.pane.key(), .result = stats };
}
