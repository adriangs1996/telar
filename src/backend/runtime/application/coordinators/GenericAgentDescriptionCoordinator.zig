const GenericAgentDescriptionRuntimePort = @import("GenericAgentDescriptionRuntimePort.zig").Type;
const AgentDescriptionResources = @import("AgentDescriptionResources.zig");
const agent_description = @import("agent_description.zig");
const std = @import("std");
const ResultType = @import("../../../agent/Result.zig");

/// Creates a statically dispatched agent-description coordinator.
///
/// ```zig
/// const AgentDescriptionCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericAgentDescriptionRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: AgentDescriptionResources,

        /// Binds one runtime's agent tracker, generator configuration, and
        /// single-flight actor state.
        ///
        /// ```zig
        /// var coordinator = AgentDescriptionCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: AgentDescriptionResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one configured generator job. Scheduler failure is
        /// committed as a failed aggregate result; the caller remains
        /// responsible for the delivery opportunity surrounding this call.
        ///
        /// ```zig
        /// _ = coordinator.schedule();
        /// ```
        pub fn schedule(coordinator: *Self) agent_description.ScheduleResult {
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
        pub fn handle(coordinator: *Self, result: ResultType) void {
            coordinator.resources.state.complete();
            _ = coordinator.commit(result);
            _ = coordinator.schedule();
            port.pump_clients(coordinator.context);
        }

        fn commit(coordinator: *Self, result: ResultType) bool {
            const finished = coordinator.resources.agents.finishDescription(&result) orelse return false;
            port.persist(coordinator.context, finished);
            return true;
        }
    };
}
