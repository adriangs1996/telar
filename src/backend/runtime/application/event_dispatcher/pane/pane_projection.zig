const core = @import("telar-core");
const ProbeType = @import("../../../../process/Probe.zig");
const sound_module = @import("../../../../agent/sound.zig");
const agents = @import("../agent_events.zig");
const io_events = @import("pane_io.zig");

const ProcessReconciliation = @import("../../../entrypoints/events/pane/ProcessReconciliation.zig");
const agent_identity = @import("../../coordinators/agent_identity.zig");
const ScreenReconciliation = @import("../../../entrypoints/events/pane/ScreenReconciliation.zig");

const std = @import("std");
const ObservationCompletion = @import("../../../entrypoints/events/pane/ObservationCompletion.zig");
const MediaCompletion = @import("../../../entrypoints/events/pane/MediaCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const ObservationWork = @import("../../../entrypoints/events/pane/ObservationWork.zig");
const StatsType = @import("../../../../history/Stats.zig");
const agent_process = @import("../../../../process/process.zig");
const MediaWork = @import("../../../entrypoints/events/pane/MediaWork.zig");
const MediaStats = @import("../../../../media/Stats.zig");
const root = @import("../../../attachment/attachment_namespace.zig");
const PaneStats = @import("../../../entrypoints/events/pane/Stats.zig");
const store_support = @import("../../../client/store_support.zig");
const AttachmentStoreType = @import("../../../attachment/AttachmentStore.zig");
const media_projection_module = @import("../../../entrypoints/events/pane/media_projection.zig");

const Application = @import("../../Application.zig");

/// Applies one process/output observation to the pane and agent
/// aggregates, then schedules any resulting description work.
///
/// ```zig
/// try PaneProjectionEvents.handleObserved(&application, event);
/// ```
pub fn handleObserved(application: *Application, event: ObservationCompletion) !void {
    const previous = application.model.agents.resumeSession(event.pane);
    defer {
        const current = application.model.agents.resumeSession(event.pane);
        const changed = if (previous) |before|
            if (current) |after| !before.eql(after) else true
        else
            current != null;
        if (changed) {
            application.noteSessionChange();
        }
    }

    try completeObservation(application, event);
}

/// Applies one decoded media projection, synchronizes client
/// attachments and schedules any generated terminal response.
///
/// ```zig
/// try PaneProjectionEvents.handleMedia(&application, event);
/// ```
pub fn handleMedia(application: *Application, completion: MediaCompletion) !void {
    const pane = application.model.panes.resolve(completion.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    pane.completeMediaProcessing();
    observeMediaMetrics(application, completion.stats);
    root.enforceGraphicsQuotas(application.io, pane);
    pane.refreshGraphicsProjection();

    const projection = synchronizeMediaClients(application, pane, completion.stats.reset);
    if (comptime core.enabled) {
        application.metrics.graphics_transfers_staged +|= projection.staged;
    }

    try io_events.scheduleResponse(application, pane);
    application.pumpAll();
    try scheduleMedia(application, pane);
    application.collect();
    application.pumpAll();
}

/// Starts a pane observation when its single-flight state permits it.
///
/// ```zig
/// try PaneProjectionEvents.scheduleObservation(&application, pane);
/// ```
pub fn scheduleObservation(application: *Application, pane: *PaneType) !void {
    const borrow = pane.beginHistoryObservation() orelse return;
    const work: ObservationWork = .{
        .pane = pane,
        .current_size = borrow.current_size,
        .process_cache = borrow.process_cache,
    };

    startPaneObservation(application, work) catch |err| {
        pane.cancelHistoryObservation();
        return err;
    };
}

/// Starts media processing when the pane has pending media work and no
/// media operation is already in flight.
///
/// ```zig
/// try PaneProjectionEvents.scheduleMedia(&application, pane);
/// ```
pub fn scheduleMedia(application: *Application, pane: *PaneType) !void {
    const borrow = pane.beginMediaProcessing() orelse return;
    const work: MediaWork = .{ .pane = pane, .current_size = borrow.current_size };

    startPaneMedia(application, work) catch |err| {
        pane.cancelMediaProcessing();
        return err;
    };
}

fn startPaneObservation(application: *Application, work: ObservationWork) !void {
    try application.select.concurrent(.pane_observed, observePane, .{work});
}

fn observePane(work: ObservationWork) ObservationCompletion {
    const path = core.enter(.observation);
    defer path.restore();

    var stats: StatsType = .{};
    const process_probe = agent_process.probe(.{
        .process_group_id = work.pane.session.foregroundProcessGroup(),
        .previous = work.process_cache,
        .manifests = work.pane.manifests,
    });
    work.pane.processHistoryObservation(.{ .size = work.current_size, .provider = process_probe.cache.provider }, &stats);
    return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
}

fn publishObservedAgentSound(application: *Application, notification: core.AgentSoundNotification) void {
    application.publishAgentSound(notification);
}

fn startPaneMedia(application: *Application, work: MediaWork) !void {
    try application.select.concurrent(.pane_media, processPaneMedia, .{work});
}

fn processPaneMedia(work: MediaWork) MediaCompletion {
    const path = core.enter(.media);
    defer path.restore();

    var stats: MediaStats = .{};
    const started = core.now(work.pane.io);
    work.pane.processMedia(work.current_size, &stats);
    stats.elapsed_ns = core.elapsed(started, core.now(work.pane.io));
    return .{ .pane = work.pane.key(), .stats = stats };
}

fn synchronizeMediaClients(application: *Application, pane: *PaneType, reset: bool) PaneStats {
    var stores: [store_support.max_clients]*AttachmentStoreType = undefined;
    var count: usize = 0;

    for (&application.clients.items) |*slot| {
        const client = slot.* orelse continue;
        stores[count] = &client.attachments;
        count += 1;
    }

    return media_projection_module.synchronize(pane, stores[0..count], reset);
}

fn completeObservation(application: *Application, completion: ObservationCompletion) !void {
    const pane = application.model.panes.resolve(completion.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    const transition = pane.completeHistoryObservation(completion.process_probe.cache);
    if (transition.cwd_changed) {
        application.model.agents.touch();
    }

    observeProcessMetrics(application, completion.process_probe);
    reconcileProcess(application, .{
        .pane = pane,
        .probe = completion.process_probe,
        .transition = transition,
    });
    observeHistoryMetrics(application, completion.stats);
    reconcileScreen(application, .{
        .pane = pane,
        .stats = completion.stats,
        .shell_foreground = transition.shell_foreground,
    });

    agents.scheduleDescription(application);
    try scheduleObservation(application, pane);
    application.collect();
    application.pumpAll();
}

fn observeProcessMetrics(application: *Application, probe: ProbeType) void {
    if (comptime !core.enabled) {
        return;
    }

    if (!probe.inspected) {
        return;
    }

    application.metrics.agent_process_inspections +|= 1;
    if (probe.cache.provider == .unknown) {
        application.metrics.agent_process_misses +|= 1;
    }
}

fn reconcileProcess(application: *Application, reconciliation: ProcessReconciliation) void {
    if (!reconciliation.probe.changed) {
        return;
    }

    if (reconciliation.probe.cache.provider != .unknown) {
        _ = application.model.agents.observeProcess(.{
            .identity = agent_identity.fromPane(reconciliation.pane),
            .provider = reconciliation.probe.cache.provider,
            .process_id = reconciliation.probe.cache.process_group_id.?,
            .observed_at_ms = (std.Io.Timestamp.now(application.io, .real).toMilliseconds()),
        });
        return;
    }

    if (reconciliation.transition.shell_foreground) {
        if (application.model.agents.awaitingResume(reconciliation.pane.key())) {
            return;
        }

        _ = application.model.agents.remove(reconciliation.pane.key());
        return;
    }

    if (reconciliation.transition.previous_process.provider != .unknown) {
        _ = application.model.agents.clearProcess(reconciliation.pane.key());
    }
}

fn observeHistoryMetrics(application: *Application, stats: StatsType) void {
    if (comptime !core.enabled) {
        return;
    }

    application.metrics.history_candidate_input_bytes +|= stats.input_bytes;
    application.metrics.history_captured +|= stats.captured;
    application.metrics.history_dropped +|= stats.dropped;

    if (stats.failed) {
        application.metrics.history_observation_failures +|= 1;
    }

    if (stats.reset) {
        application.metrics.history_observation_resets +|= 1;
    }
}

fn reconcileScreen(application: *Application, reconciliation: ScreenReconciliation) void {
    const observation = reconciliation.stats.agent_observation orelse return;
    if (reconciliation.shell_foreground) {
        return;
    }

    const identity = agent_identity.fromPane(reconciliation.pane);
    const previous_status = application.model.agents.projectedStatus(identity.key);
    const changed = application.model.agents.observeScreen(.{
        .identity = identity,
        .signal = observation.signal,
        .observed_at_ms = observation.observed_at_ms,
        .observed_at_ns = observation.observed_at_ns,
    });
    if (!changed) {
        return;
    }

    const sound = sound_module.soundForTransition(
        previous_status,
        application.model.agents.projectedStatus(identity.key),
    ) orelse return;
    publishObservedAgentSound(application, .{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = sound,
    });
}

fn observeMediaMetrics(application: *Application, stats: MediaStats) void {
    if (comptime !core.enabled) {
        return;
    }

    application.metrics.media_bytes +|= stats.output_bytes;
    application.metrics.media_discarded_frames +|= stats.discarded_frames;
    application.metrics.media_unavailable_frames +|= stats.unavailable_frames;
    application.metrics.media_forwarded_frames +|= stats.forwarded_frames;
    application.metrics.graphics_transfers_prepared +|= stats.prepared_frames;
    application.metrics.media_direct_frames +|= stats.direct_frames;
    application.metrics.media_file_frames +|= stats.file_frames;
    application.metrics.media_ingest.observe(stats.elapsed_ns);

    if (stats.failed) {
        application.metrics.media_failures +|= 1;
    }

    if (stats.reset) {
        application.metrics.media_resets +|= 1;
    }
}
