const GenericExitRuntimePort = @import("GenericExitRuntimePort.zig").Type;
const ExitResources = @import("ExitResources.zig");
const ExitCompletion = @import("ExitCompletion.zig");
const exit_ops = @import("exit.zig");

/// Creates a statically dispatched pane-exit coordinator.
///
/// ```zig
/// const ExitCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericExitRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: ExitResources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var coordinator = ExitCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: ExitResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Commits one generation-matched exit, retires agent and credential
        /// state, and queues exit history once PTY output is already drained.
        /// Wait failures become a synthetic SIGKILL exit.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: ExitCompletion) !void {
            const transition = coordinator.resources.panes.completeExit(
                completion.pane,
                exit_ops.exitOrSynthetic(completion.result),
            ) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            _ = coordinator.resources.agents.remove(transition.pane.key());
            port.revoke_credential(coordinator.context, transition.pane);

            if (transition.launch_aborting) {
                port.collect(coordinator.context);
                port.pump_clients(coordinator.context);
                return;
            }

            if (transition.output_done) {
                transition.pane.queueExitedHistory(transition.exit);
                try port.schedule_observation(coordinator.context, transition.pane);
            }

            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }
    };
}
