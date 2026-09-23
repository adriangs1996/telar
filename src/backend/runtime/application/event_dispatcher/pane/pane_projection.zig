const core = @import("telar-core");
const ProbeType = @import("../../../../process/Probe.zig");
const sound_module = @import("../../../../agent/sound.zig");
const agents = @import("../agent_events.zig");
const pane_input = @import("../../../pane_input.zig");
const agent_sound = @import("../../../agent_sound.zig");

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

const RuntimeModel = @import("../../../RuntimeModel.zig");

/// Applies one process/output observation to the pane and agent
/// aggregates, then schedules any resulting description work.
///
/// ```zig
/// try PaneProjectionEvents.handleObserved(&model, event);
/// ```
pub fn handleObserved(model: *RuntimeModel, event: ObservationCompletion) !void {
    const previous = model.agents.resumeSession(event.pane);
    defer {
        const current = model.agents.resumeSession(event.pane);
        const changed = if (previous) |before|
            if (current) |after| !before.eql(after) else true
        else
            current != null;
        if (changed) {
            model.noteSessionChange();
        }
    }

    try completeObservation(model, event);
}

/// Applies one decoded media projection, synchronizes client
/// attachments and schedules any generated terminal response.
///
/// ```zig
/// try PaneProjectionEvents.handleMedia(&model, event);
/// ```
pub fn handleMedia(model: *RuntimeModel, completion: MediaCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    pane.completeMediaProcessing();
    observeMediaMetrics(model, completion.stats);
    root.enforceGraphicsQuotas(model.io, pane);
    pane.refreshGraphicsProjection();

    const projection = synchronizeMediaClients(model, pane, completion.stats.reset);
    if (comptime core.enabled) {
        model.metrics.graphics_transfers_staged +|= projection.staged;
    }

    try pane_input.startResponseWrite(model, pane);
}

/// Starts a pane observation when its single-flight state permits it.
///
/// ```zig
/// try PaneProjectionEvents.scheduleObservation(&model, pane);
/// ```
pub fn scheduleObservation(model: *RuntimeModel, pane: *PaneType) !void {
    const borrow = pane.beginHistoryObservation() orelse return;
    const work: ObservationWork = .{
        .pane = pane,
        .current_size = borrow.current_size,
        .process_cache = borrow.process_cache,
    };

    startPaneObservation(model, work) catch |err| {
        pane.cancelHistoryObservation();
        return err;
    };
}

/// Starts media processing when the pane has pending media work and no
/// media operation is already in flight.
///
/// ```zig
/// try PaneProjectionEvents.scheduleMedia(&model, pane);
/// ```
pub fn scheduleMedia(model: *RuntimeModel, pane: *PaneType) !void {
    const borrow = pane.beginMediaProcessing() orelse return;
    const work: MediaWork = .{ .pane = pane, .current_size = borrow.current_size };

    startPaneMedia(model, work) catch |err| {
        pane.cancelMediaProcessing();
        return err;
    };
}

fn startPaneObservation(model: *RuntimeModel, work: ObservationWork) !void {
    try model.select.concurrent(.pane_observed, observePane, .{work});
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

fn publishObservedAgentSound(model: *RuntimeModel, notification: core.AgentSoundNotification) void {
    agent_sound.publish(model, notification);
}

fn startPaneMedia(model: *RuntimeModel, work: MediaWork) !void {
    try model.select.concurrent(.pane_media, processPaneMedia, .{work});
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

fn synchronizeMediaClients(model: *RuntimeModel, pane: *PaneType, reset: bool) PaneStats {
    var stores: [store_support.max_clients]*AttachmentStoreType = undefined;
    var count: usize = 0;

    for (&model.clients.items) |*slot| {
        const client = slot.* orelse continue;
        stores[count] = &client.attachments;
        count += 1;
    }

    return media_projection_module.synchronize(pane, stores[0..count], reset);
}

fn completeObservation(model: *RuntimeModel, completion: ObservationCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const transition = pane.completeHistoryObservation(completion.process_probe.cache);
    if (transition.cwd_changed) {
        model.agents.touch();
    }

    observeProcessMetrics(model, completion.process_probe);
    reconcileProcess(model, .{
        .pane = pane,
        .probe = completion.process_probe,
        .transition = transition,
    });
    observeHistoryMetrics(model, completion.stats);
    reconcileScreen(model, .{
        .pane = pane,
        .stats = completion.stats,
        .shell_foreground = transition.shell_foreground,
    });

    agents.scheduleDescription(model);
    try scheduleObservation(model, pane);
}

fn observeProcessMetrics(model: *RuntimeModel, probe: ProbeType) void {
    if (comptime !core.enabled) {
        return;
    }

    if (!probe.inspected) {
        return;
    }

    model.metrics.agent_process_inspections +|= 1;
    if (probe.cache.provider == .unknown) {
        model.metrics.agent_process_misses +|= 1;
    }
}

fn reconcileProcess(model: *RuntimeModel, reconciliation: ProcessReconciliation) void {
    if (!reconciliation.probe.changed) {
        return;
    }

    if (reconciliation.probe.cache.provider != .unknown) {
        _ = model.agents.observeProcess(.{
            .identity = agent_identity.fromPane(reconciliation.pane),
            .provider = reconciliation.probe.cache.provider,
            .process_id = reconciliation.probe.cache.process_group_id.?,
            .observed_at_ms = (std.Io.Timestamp.now(model.io, .real).toMilliseconds()),
        });
        return;
    }

    if (reconciliation.transition.shell_foreground) {
        if (model.agents.awaitingResume(reconciliation.pane.key())) {
            return;
        }

        _ = model.agents.remove(reconciliation.pane.key());
        return;
    }

    if (reconciliation.transition.previous_process.provider != .unknown) {
        _ = model.agents.clearProcess(reconciliation.pane.key());
    }
}

fn observeHistoryMetrics(model: *RuntimeModel, stats: StatsType) void {
    if (comptime !core.enabled) {
        return;
    }

    model.metrics.history_candidate_input_bytes +|= stats.input_bytes;
    model.metrics.history_captured +|= stats.captured;
    model.metrics.history_dropped +|= stats.dropped;

    if (stats.failed) {
        model.metrics.history_observation_failures +|= 1;
    }

    if (stats.reset) {
        model.metrics.history_observation_resets +|= 1;
    }
}

fn reconcileScreen(model: *RuntimeModel, reconciliation: ScreenReconciliation) void {
    const observation = reconciliation.stats.agent_observation orelse return;
    if (reconciliation.shell_foreground) {
        return;
    }

    const identity = agent_identity.fromPane(reconciliation.pane);
    const previous_status = model.agents.projectedStatus(identity.key);
    const changed = model.agents.observeScreen(.{
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
        model.agents.projectedStatus(identity.key),
    ) orelse return;
    publishObservedAgentSound(model, .{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = sound,
    });
}

fn observeMediaMetrics(model: *RuntimeModel, stats: MediaStats) void {
    if (comptime !core.enabled) {
        return;
    }

    model.metrics.media_bytes +|= stats.output_bytes;
    model.metrics.media_discarded_frames +|= stats.discarded_frames;
    model.metrics.media_unavailable_frames +|= stats.unavailable_frames;
    model.metrics.media_forwarded_frames +|= stats.forwarded_frames;
    model.metrics.graphics_transfers_prepared +|= stats.prepared_frames;
    model.metrics.media_direct_frames +|= stats.direct_frames;
    model.metrics.media_file_frames +|= stats.file_frames;
    model.metrics.media_ingest.observe(stats.elapsed_ns);

    if (stats.failed) {
        model.metrics.media_failures +|= 1;
    }

    if (stats.reset) {
        model.metrics.media_resets +|= 1;
    }
}
