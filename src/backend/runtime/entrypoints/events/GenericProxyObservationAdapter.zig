const GenericProxyObservationRuntimePort = @import("GenericProxyObservationRuntimePort.zig").Type;
const ProxyObservationResources = @import("ProxyObservationResources.zig");
const ObservationType = @import("../../../proxy/Observation.zig");
const enabled_module = @import("telar-core").enabled;
const proxy_observation = @import("proxy_observation.zig");

/// Creates a statically dispatched proxy-observation adapter.
///
/// ```zig
/// const ProxyObservationAdapter = Adapter(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericProxyObservationRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: ProxyObservationResources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var adapter = ProxyObservationAdapter.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: ProxyObservationResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms successful proxy receives before validating their pane
        /// generation. Live inference events are translated into agent-domain
        /// evidence; receive failures and auxiliary traffic are discarded.
        ///
        /// ```zig
        /// try adapter.handle(receive_result);
        /// ```
        pub fn handle(adapter: *Self, result: anyerror!ObservationType) !void {
            const event = result catch return;
            try port.rearm_receive(adapter.context);

            const pane = adapter.resources.panes.resolve(event.pane) orelse {
                adapter.resources.metrics.stale_pane_events += 1;
                return;
            };

            if (comptime enabled_module) {
                adapter.resources.metrics.proxy_observations +|= 1;
            }

            const observation = proxy_observation.translate(event, pane) orelse return;
            _ = adapter.resources.agents.observeProxy(observation);
            port.schedule_description(adapter.context);
            port.pump_clients(adapter.context);
        }
    };
}
