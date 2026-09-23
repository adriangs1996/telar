const core = @import("telar-core");
const pane_input = @import("../../../pane_input.zig");
const pane_attachment = @import("../../../pane_attachment.zig");
const projection = @import("pane_projection.zig");
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const std = @import("std");
const exit_ops = @import("../../../entrypoints/events/pane/exit.zig");
const OutputCompletion = @import("../../../entrypoints/events/pane/OutputCompletion.zig");
const IngestTestGateType = @import("../../../IngestTestGate.zig");
const IngestCompletion = @import("../../../entrypoints/events/pane/IngestCompletion.zig");
const ExitCompletion = @import("../../../entrypoints/events/pane/ExitCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const OutputIngest = @import("../../../entrypoints/events/pane/OutputIngest.zig");
const PaneIngestStats = @import("../../../../pane/PaneIngestStats.zig");
const ReadType = @import("../../../entrypoints/events/pane/Read.zig");
const pane_launch = @import("../../../pane_launch.zig");

const RuntimeModel = @import("../../../RuntimeModel.zig");

/// Classifies one PTY read into observation, media and terminal-ingest
/// work without performing slow projection work on the event-loop path.
///
/// ```zig
/// try PanePipelineEvents.handleOutput(&model, event, ingest_gate);
/// ```
pub fn handleOutput(model: *RuntimeModel, event: OutputCompletion, ingest_gate: ?*IngestTestGateType) !void {
    core.mark(model.io, .output_dispatch);
    var context: OutputRuntime = .{ .model = model, .ingest_gate = ingest_gate };
    try processOutput(&context, event);

    if (context.inline_ingest) |result| {
        try handleIngested(model, result);
    }
}

/// Commits one terminal-ingest result, refreshes attachments and rearms
/// the pane's next PTY read.
///
/// ```zig
/// try PanePipelineEvents.handleIngested(&model, event);
/// ```
pub fn handleIngested(model: *RuntimeModel, event: IngestCompletion) !void {
    core.mark(model.io, .ingest_dispatch);
    try commitIngest(model, event);
}

/// Applies one pane-process exit, revokes its proxy credential and
/// schedules the final observation before lifecycle collection.
///
/// ```zig
/// try PanePipelineEvents.handleExit(&model, event);
/// ```
pub fn handleExit(model: *RuntimeModel, completion: ExitCompletion) !void {
    const transition = model.panes.completeExit(
        completion.pane,
        exit_ops.exitOrSynthetic(completion.result),
    ) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    _ = model.agents.remove(transition.pane.key());
    model.revokePaneCredential(transition.pane);

    if (transition.launch_aborting) {
        return;
    }

    if (transition.output_done) {
        transition.pane.queueExitedHistory(transition.exit);
        try projection.scheduleObservation(model, transition.pane);
    }
}

const OutputRuntime = @import("OutputRuntime.zig");

const PaneIngestTask = @import("PaneIngestTask.zig");

fn startOutputIngest(context: *OutputRuntime, ingest: OutputIngest) !void {
    core.mark(ingest.io, .vt_queued);
    const task: PaneIngestTask = .{ .ingest = ingest, .gate = context.ingest_gate };

    if (context.ingest_gate == null and ingest.pane.canInlineOutput(ingest.bytes)) {
        context.inline_ingest = ingestPane(task);
        return;
    }

    try context.model.select.concurrent(.pane_ingested, ingestPane, .{task});
}

fn paneHasOutstandingFrame(context: *OutputRuntime, pane_id: core.PaneId) bool {
    for (&context.model.clients.items) |*slot| {
        const client = slot.* orelse continue;
        const attachment = client.attachments.find(pane_id) orelse continue;

        if (attachment.outstandingFrameId() != 0) {
            return true;
        }
    }

    return false;
}

fn ingestPane(task: PaneIngestTask) IngestCompletion {
    core.profiling.add(.runtime_ingest, 1);
    core.profiling.add(.runtime_ingest_bytes, task.ingest.bytes.len);
    const profile_started = core.profiling.start(task.ingest.io);
    defer core.profiling.finish(task.ingest.io, .runtime_ingest, profile_started);
    core.mark(task.ingest.io, .vt_start);
    defer core.mark(task.ingest.io, .vt_done);

    const path = core.enter(.interactive);
    defer path.restore();

    if (task.gate) |gate| {
        gate.wait(task.ingest.io) catch |err| {
            return .{ .pane = task.ingest.pane.key(), .result = err };
        };
    }

    var stats: PaneIngestStats = .{};
    stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
        return .{ .pane = task.ingest.pane.key(), .result = err };
    };

    return .{ .pane = task.ingest.pane.key(), .result = stats };
}

fn refreshPaneClients(model: *RuntimeModel, pane: *PaneType) void {
    for (&model.clients.items) |*slot| {
        const client = slot.* orelse continue;
        const attachment = client.attachments.find(pane.id) orelse continue;

        _ = attachment.resizeIfNeeded() catch {
            _ = pane_attachment.detachPane(model, client, pane.id);
        };
    }
}

fn startNextPaneRead(model: *RuntimeModel, read: ReadType) !void {
    try model.select.concurrent(.pane_output, pane_launch.readPane, .{ read.io, read.pane });
}

fn processOutput(context: *OutputRuntime, completion: OutputCompletion) !void {
    const pane = context.model.panes.resolve(completion.pane) orelse {
        context.model.metrics.stale_pane_events += 1;
        return;
    };
    const output_len = completion.result catch {
        pane.completePtyOutputRead(.finished);
        return finishOutput(context, pane);
    };

    if (output_len == 0) {
        pane.completePtyOutputRead(.finished);
        return finishOutput(context, pane);
    }

    pane.completePtyOutputRead(.data);

    if (comptime core.enabled) {
        context.model.metrics.pty_events += 1;
        context.model.metrics.pty_bytes += output_len;

        if (paneHasOutstandingFrame(context, pane.id)) {
            context.model.metrics.folded_pty_events += 1;
        }
    }

    const bytes = pane.output_buffer[0..output_len];
    const shell_foreground = pane.session.shellForeground();
    pane.expireProgress(shell_foreground orelse false);
    pane.queueHistoryOutput(.{
        .bytes = bytes,
        .shell_foreground = shell_foreground,
        .clock = pane_mod.historyClock(context.model.io),
    });
    try (projection.scheduleObservation(context.model, pane));

    pane.queueMediaOutput(bytes);
    try (projection.scheduleMedia(context.model, pane));

    const ingest: OutputIngest = .{
        .io = context.model.io,
        .pane = pane,
        .bytes = pane.beginOutputIngest(output_len),
    };
    startOutputIngest(context, ingest) catch |err| {
        pane.cancelOutputIngest();
        return err;
    };
}

fn finishOutput(context: *OutputRuntime, pane: *PaneType) !void {
    if (pane.exit) |exit| {
        pane.queueExitedHistory(exit);
        try (projection.scheduleObservation(context.model, pane));
    }
}

fn commitIngest(model: *RuntimeModel, completion: IngestCompletion) !void {
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
    try projection.scheduleObservation(model, pane);
    try projection.scheduleMedia(model, pane);
    refreshPaneClients(model, pane);
    try pane_input.startResponseWrite(model, pane);

    const read: ReadType = .{
        .io = model.io,
        .pane = pane,
    };
    const read_started = pane.beginPtyOutputRead();
    std.debug.assert(read_started);
    startNextPaneRead(model, read) catch |err| {
        pane.cancelPtyOutputRead();
        return err;
    };
}
