const core = @import("telar-core");
const io_events = @import("pane_io.zig");
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
const pane_launcher_mod = @import("../../pane_launcher.zig");

const Application = @import("../../Application.zig");

/// Classifies one PTY read into observation, media and terminal-ingest
/// work without performing slow projection work on the event-loop path.
///
/// ```zig
/// try PanePipelineEvents.handleOutput(&application, event, ingest_gate);
/// ```
pub fn handleOutput(application: *Application, event: OutputCompletion, ingest_gate: ?*IngestTestGateType) !void {
    core.mark(application.io, .output_dispatch);
    var context: OutputRuntime = .{ .application = application, .ingest_gate = ingest_gate };
    try processOutput(&context, event);

    if (context.inline_ingest) |result| {
        try handleIngested(application, result);
    }
}

/// Commits one terminal-ingest result, refreshes attachments and rearms
/// the pane's next PTY read.
///
/// ```zig
/// try PanePipelineEvents.handleIngested(&application, event);
/// ```
pub fn handleIngested(application: *Application, event: IngestCompletion) !void {
    core.mark(application.io, .ingest_dispatch);
    try commitIngest(application, event);
}

/// Applies one pane-process exit, revokes its proxy credential and
/// schedules the final observation before lifecycle collection.
///
/// ```zig
/// try PanePipelineEvents.handleExit(&application, event);
/// ```
pub fn handleExit(application: *Application, completion: ExitCompletion) !void {
    const transition = application.model.panes.completeExit(
        completion.pane,
        exit_ops.exitOrSynthetic(completion.result),
    ) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    _ = application.model.agents.remove(transition.pane.key());
    application.revokePaneCredential(transition.pane);

    if (transition.launch_aborting) {
        application.collect();
        application.pumpAll();
        return;
    }

    if (transition.output_done) {
        transition.pane.queueExitedHistory(transition.exit);
        try projection.scheduleObservation(application, transition.pane);
    }

    application.collect();
    application.pumpAll();
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

    try context.application.select.concurrent(.pane_ingested, ingestPane, .{task});
}

fn paneHasOutstandingFrame(context: *OutputRuntime, pane_id: core.PaneId) bool {
    for (&context.application.clients.items) |*slot| {
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

fn refreshPaneClients(application: *Application, pane: *PaneType) void {
    for (&application.clients.items) |*slot| {
        const client = slot.* orelse continue;
        const attachment = client.attachments.find(pane.id) orelse continue;

        _ = attachment.resizeIfNeeded() catch {
            _ = application.detachSessionPane(client, pane.id);
        };
    }
}

fn startNextPaneRead(application: *Application, read: ReadType) !void {
    try application.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
}

fn processOutput(context: *OutputRuntime, completion: OutputCompletion) !void {
    const pane = context.application.model.panes.resolve(completion.pane) orelse {
        context.application.metrics.stale_pane_events += 1;
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
        context.application.metrics.pty_events += 1;
        context.application.metrics.pty_bytes += output_len;

        if (paneHasOutstandingFrame(context, pane.id)) {
            context.application.metrics.folded_pty_events += 1;
        }
    }

    const bytes = pane.output_buffer[0..output_len];
    const shell_foreground = pane.session.shellForeground();
    pane.expireProgress(shell_foreground orelse false);
    pane.queueHistoryOutput(.{
        .bytes = bytes,
        .shell_foreground = shell_foreground,
        .clock = pane_mod.historyClock(context.application.io),
    });
    try (projection.scheduleObservation(context.application, pane));

    pane.queueMediaOutput(bytes);
    try (projection.scheduleMedia(context.application, pane));

    const ingest: OutputIngest = .{
        .io = context.application.io,
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
        try (projection.scheduleObservation(context.application, pane));
    }

    context.application.collect();
    context.application.pumpAll();
}

fn commitIngest(application: *Application, completion: IngestCompletion) !void {
    const pane = application.model.panes.resolve(completion.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    pane.completeOutputIngest();
    const stats = completion.result catch {
        _ = pane.requestClose();
        pane.finishPtyOutput();
        application.collect();
        return;
    };

    if (comptime core.enabled) {
        application.metrics.ingest.observe(stats.elapsed_ns);
    }

    pane.applyPendingResize() catch {
        _ = pane.requestClose();
    };
    try projection.scheduleObservation(application, pane);
    try projection.scheduleMedia(application, pane);
    refreshPaneClients(application, pane);
    try io_events.scheduleResponse(application, pane);

    const read: ReadType = .{
        .io = application.io,
        .pane = pane,
    };
    const read_started = pane.beginPtyOutputRead();
    std.debug.assert(read_started);
    startNextPaneRead(application, read) catch |err| {
        pane.cancelPtyOutputRead();
        return err;
    };

    application.collect();
    application.pumpAll();
}
