const GenericAgentDescriptionRuntimePort = @import("GenericAgentDescriptionRuntimePort.zig").Type;
const Resources = @import("AgentDescriptionResources.zig");
const source_namespace = @import("agent_description.zig");
const std = @import("std");
/// Creates a statically dispatched agent-description coordinator.
///
/// ```zig
/// const AgentDescriptionCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericAgentDescriptionRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's agent tracker, generator configuration, and
        /// single-flight actor state.
        ///
        /// ```zig
        /// var coordinator = AgentDescriptionCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one configured generator job. Scheduler failure is
        /// committed as a failed aggregate result; the caller remains
        /// responsible for the delivery opportunity surrounding this call.
        ///
        /// ```zig
        /// _ = coordinator.schedule();
        /// ```
        pub fn schedule(coordinator: *Self) source_namespace.ScheduleResult {
            const command = coordinator.resources.command orelse return .no_work;
            if (coordinator.resources.state.isPending()) {
                return .no_work;
            }

            var job = coordinator.resources.agents.nextDescriptionJob() orelse return .no_work;
            defer std.crypto.secureZero(u8, &job.query);

            port.start(coordinator.context, command, job) catch {
                _ = coordinator.commit(.{
                    .pane = job.pane,
                    .session_id = job.session_id,
                    .status = .failed,
                });
                return .failed;
            };

            coordinator.resources.state.begin();
            return .started;
        }

        /// Releases the completed actor slot, applies only an exact aggregate
        /// result, persists the validated domain event, starts the next queued
        /// job, then gives clients one delivery opportunity.
        ///
        /// ```zig
        /// coordinator.handle(result);
        /// ```
        pub fn handle(coordinator: *Self, result: source_namespace.description.Result) void {
            coordinator.resources.state.complete();
            _ = coordinator.commit(result);
            _ = coordinator.schedule();
            port.pump_clients(coordinator.context);
        }

        fn commit(coordinator: *Self, result: source_namespace.description.Result) bool {
            const finished = coordinator.resources.agents.finishDescription(&result) orelse return false;
            port.persist(coordinator.context, finished);
            return true;
        }
    };
}
