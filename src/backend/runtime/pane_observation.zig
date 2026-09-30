//! An observation actor reads the pane's process tree and recent output
//! off the interactive path; its result updates the pane's cwd and
//! foreground and reconciles the agent evidence it carries.
const agent_status = @import("agent_status.zig");

const revisions = @import("../revisions.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Pane = @import("../pane/Pane.zig");
const HistoryObservationCompletion = @import("../pane/HistoryObservationCompletion.zig");
const HistoryStats = @import("../history/Stats.zig");
const Probe = @import("../process/Probe.zig");
const ObservationCompletion = @import("events/ObservationCompletion.zig");
const Cache = @import("../process/Cache.zig");
const agent_control = @import("agent_control.zig");
const agent_description = @import("agent_description.zig");
const agent_identity = @import("agent_identity.zig");
const agent_process = @import("../process/process.zig");
const agent_sound = @import("agent_sound.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const sound = @import("../agent/sound.zig");
const providers = @import("../agent/providers/providers.zig");
const hook_integration = @import("../agent/hook_integration.zig");
const agent_hooks = @import("agent_hooks.zig");

/// Starts the pane's single observation actor when it may run.
///
/// ```zig
/// try pane_observation.start(model, pane);
/// ```
pub fn start(model: *RuntimeModel, pane: *Pane) !void {
    const borrow = pane.beginHistoryObservation() orelse return;
    const work: ObservationWork = .{
        .pane = pane,
        .current_size = borrow.current_size,
        .process_cache = borrow.process_cache,
    };

    model.select.concurrent(.pane_observed, observe, .{work}) catch |err| {
        pane.cancelHistoryObservation();
        return err;
    };
}

/// Commits one observation, reconciles process and screen evidence with the
/// pane's agent and starts the next observation when output is pending.
///
/// ```zig
/// try pane_observation.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: ObservationCompletion) !void {
    const previous = agent_status.resumeSession(model, completion.pane);
    defer {
        const current = agent_status.resumeSession(model, completion.pane);
        const changed = if (previous) |before|
            if (current) |after| !before.eql(after) else true
        else
            current != null;
        if (changed) {
            session_checkpoint.noteChange(model);
        }
    }

    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const transition = pane.completeHistoryObservation(completion.process_probe.cache);
    const slot = model.panes.index.get(core.raw(pane.id)).?;
    model.panes.shell_markers[slot] = completion.stats.shell_markers and !completion.stats.failed;
    if (transition.cwd_changed) {
        revisions.advance(&model.panes.revision);
    }

    recordProcessMetrics(model, completion.process_probe);
    reconcileProcess(model, pane, completion.process_probe, transition);
    recordHistoryMetrics(model, completion.stats);
    // Before the screen can settle an interrupt: a composer that reads as
    // ready may still hold the prompt the agent put back.
    try agent_control.clearRestoredDraft(model, pane);
    reconcileScreen(model, pane, completion.stats, transition.shell_foreground);

    agent_description.start(model);
    agent_hooks.answerParked(model, completion.pane);
    try start(model, pane);
}

fn observe(work: ObservationWork) ObservationCompletion {
    const path = core.enter(.observation);
    defer path.restore();

    var stats: HistoryStats = .{};
    var process_probe = agent_process.probe(.{
        .process_group_id = work.pane.session.foregroundProcessGroup(),
        .previous = work.process_cache,
        .manifests = work.pane.manifests,
    });
    if (process_probe.inspected) {
        process_probe.cache.hooks_installed = hooksInstalled(process_probe.cache);
    }

    work.pane.processHistoryObservation(.{ .size = work.current_size, .provider = process_probe.cache.provider }, &stats);
    return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
}

// Only a session that may run on a shared server needs to know: the card
// suggests how to start it only to someone who installed telar's hooks.
fn hooksInstalled(cache: Cache) bool {
    if (cache.session_host != .shared_server) {
        return false;
    }

    const settings = providers.of(cache.provider).hook_settings orelse return false;
    const override = if (settings.environment()) |name| environmentValue(name) else null;
    return hook_integration.installed(settings, override, environmentValue("HOME"));
}

/// Longest environment variable name a hook setting names.
const max_variable_name_bytes = 64;

// The runtime's own environment, which a worker only reads.
fn environmentValue(name: []const u8) ?[]const u8 {
    var name_buffer: [max_variable_name_bytes]u8 = undefined;
    const terminated = std.fmt.bufPrintZ(&name_buffer, "{s}", .{name}) catch return null;
    const value = std.c.getenv(terminated) orelse return null;
    return std.mem.span(value);
}

fn recordProcessMetrics(model: *RuntimeModel, probe: Probe) void {
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

fn reconcileProcess(model: *RuntimeModel, pane: *Pane, probe: Probe, transition: HistoryObservationCompletion) void {
    if (!probe.changed) {
        return;
    }

    // A reporter refused for the previous process may be the new one.
    pane.rejected_reporter = null;

    if (probe.cache.provider != .unknown) {
        _ = agent_status.observeProcess(model, .{
            .identity = agent_identity.fromPane(pane),
            .provider = probe.cache.provider,
            .process_id = probe.cache.process_group_id.?,
            .session_host = probe.cache.session_host,
            .hooks_installed = probe.cache.hooks_installed,
            .agent_pid = probe.cache.agent_pid,
            .observed_at_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        });
        return;
    }

    if (transition.shell_foreground) {
        if (agent_status.awaitingResume(model, pane.key())) {
            return;
        }

        _ = agent_status.remove(model, pane.key());
        return;
    }

    if (transition.previous_process.provider != .unknown) {
        _ = agent_status.clearProcess(model, pane.key());
    }
}

fn recordHistoryMetrics(model: *RuntimeModel, stats: HistoryStats) void {
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

fn reconcileScreen(model: *RuntimeModel, pane: *Pane, stats: HistoryStats, shell_foreground: bool) void {
    const observation = stats.agent_observation orelse return;
    if (shell_foreground) {
        return;
    }

    const identity = agent_identity.fromPane(pane);
    const previous_status = agent_status.projectedStatus(model, identity.key);
    const changed = agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = observation.signal,
        .observed_at_ms = observation.observed_at_ms,
        .observed_at_ns = observation.observed_at_ns,
    });
    if (!changed) {
        return;
    }

    const transition = sound.soundForTransition(previous_status, agent_status.projectedStatus(model, identity.key)) orelse return;
    agent_sound.publish(model, .{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = transition,
    });
}

const ObservationWork = struct {
    pane: *Pane,
    current_size: core.TerminalSize,
    process_cache: Cache,
};
