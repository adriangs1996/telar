const GenericAgentMaintenanceRuntimePort = @import("GenericAgentMaintenanceRuntimePort.zig").Type;
const AgentMaintenanceResources = @import("AgentMaintenanceResources.zig");

/// Creates a statically dispatched agent-maintenance coordinator.
///
/// ```zig
/// const AgentMaintenanceCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericAgentMaintenanceRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: AgentMaintenanceResources,

        /// Binds periodic maintenance to one runtime-owned agent tracker.
        ///
        /// ```zig
        /// var coordinator = AgentMaintenanceCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: AgentMaintenanceResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms a successful timer before expiring evidence against one wall
        /// clock reading. Timer failures preserve every projection; successful
        /// maintenance always gives clients a delivery opportunity.
        ///
        /// ```zig
        /// try coordinator.handle(tick_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) !void {
            result catch return;
            try port.rearm_tick(coordinator.context);

            _ = coordinator.resources.agents.expire(port.now_ms(coordinator.context));
            port.pump_clients(coordinator.context);
        }
    };
}
