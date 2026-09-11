const GenericObservationRuntimePort = @import("GenericObservationRuntimePort.zig").Type;
const ObservationResources = @import("ObservationResources.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const ObservationWork = @import("ObservationWork.zig");
const ObservationCompletion = @import("ObservationCompletion.zig");
const ProbeType = @import("../../../../process/Probe.zig");
const enabled_module = @import("telar-core").enabled;
const ProcessReconciliation = @import("ProcessReconciliation.zig");
const agent_identity = @import("../../../application/coordinators/agent_identity.zig");
const StatsType = @import("../../../../history/Stats.zig");
const ScreenReconciliation = @import("ScreenReconciliation.zig");
const sound_module = @import("../../../../agent/sound.zig");
const std = @import("std");

/// Creates a statically dispatched observation coordinator.
///
/// ```zig
/// const ObservationCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericObservationRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: ObservationResources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var coordinator = ObservationCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: ObservationResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one history observation actor. Async-start failure
        /// releases the pane and sealed-batch borrow.
        ///
        /// ```zig
        /// try coordinator.schedule(pane);
        /// ```
        pub fn schedule(coordinator: *Self, pane: *PaneType) !void {
            const borrow = pane.beginHistoryObservation() orelse return;
            const work: ObservationWork = .{
                .pane = pane,
                .current_size = borrow.current_size,
                .process_cache = borrow.process_cache,
            };

            port.start(coordinator.context, work) catch |err| {
                pane.cancelHistoryObservation();
                return err;
            };
        }

        /// Applies one generation-matched completion, reconciles process and
        /// screen evidence, publishes exact status-transition sounds, then
        /// rearms pending observation work before lifecycle effects.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: ObservationCompletion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            const transition = pane.completeHistoryObservation(completion.process_probe.cache);
            if (transition.cwd_changed) {
                coordinator.resources.agents.touch();
            }

            coordinator.observeProcessMetrics(completion.process_probe);
            coordinator.reconcileProcess(.{
                .pane = pane,
                .probe = completion.process_probe,
                .transition = transition,
            });
            coordinator.observeHistoryMetrics(completion.stats);
            coordinator.reconcileScreen(.{
                .pane = pane,
                .stats = completion.stats,
                .shell_foreground = transition.shell_foreground,
            });

            port.schedule_description(coordinator.context);
            try coordinator.schedule(pane);
            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }

        fn observeProcessMetrics(coordinator: *Self, probe: ProbeType) void {
            if (comptime !enabled_module) {
                return;
            }

            if (!probe.inspected) {
                return;
            }

            coordinator.resources.metrics.agent_process_inspections +|= 1;
            if (probe.cache.provider == .unknown) {
                coordinator.resources.metrics.agent_process_misses +|= 1;
            }
        }

        fn reconcileProcess(coordinator: *Self, reconciliation: ProcessReconciliation) void {
            if (!reconciliation.probe.changed) {
                return;
            }

            if (reconciliation.probe.cache.provider != .unknown) {
                _ = coordinator.resources.agents.observeProcess(.{
                    .identity = agent_identity.fromPane(reconciliation.pane),
                    .provider = reconciliation.probe.cache.provider,
                    .process_id = reconciliation.probe.cache.process_group_id.?,
                    .observed_at_ms = coordinator.nowMs(),
                });
                return;
            }

            if (reconciliation.transition.shell_foreground) {
                _ = coordinator.resources.agents.remove(reconciliation.pane.key());
                return;
            }

            if (reconciliation.transition.previous_process.provider != .unknown) {
                _ = coordinator.resources.agents.clearProcess(reconciliation.pane.key());
            }
        }

        fn observeHistoryMetrics(coordinator: *Self, stats: StatsType) void {
            if (comptime !enabled_module) {
                return;
            }

            coordinator.resources.metrics.history_candidate_input_bytes +|= stats.input_bytes;
            coordinator.resources.metrics.history_captured +|= stats.captured;
            coordinator.resources.metrics.history_dropped +|= stats.dropped;

            if (stats.failed) {
                coordinator.resources.metrics.history_observation_failures +|= 1;
            }

            if (stats.reset) {
                coordinator.resources.metrics.history_observation_resets +|= 1;
            }
        }

        fn reconcileScreen(coordinator: *Self, reconciliation: ScreenReconciliation) void {
            const observation = reconciliation.stats.agent_observation orelse return;
            if (reconciliation.shell_foreground) {
                return;
            }

            const identity = agent_identity.fromPane(reconciliation.pane);
            const previous_status = coordinator.resources.agents.projectedStatus(identity.key);
            const changed = coordinator.resources.agents.observeScreen(.{
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
                coordinator.resources.agents.projectedStatus(identity.key),
            ) orelse return;
            port.publish_sound(coordinator.context, .{
                .pane_id = identity.key.id,
                .pane_generation = identity.key.generation,
                .sound = sound,
            });
        }

        fn nowMs(coordinator: *const Self) i64 {
            return std.Io.Timestamp.now(coordinator.resources.io, .real).toMilliseconds();
        }
    };
}
