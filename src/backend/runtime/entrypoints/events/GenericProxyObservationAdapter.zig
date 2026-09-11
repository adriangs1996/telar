const GenericProxyObservationRuntimePort = @import("GenericProxyObservationRuntimePort.zig").Type;
const Resources = @import("ProxyObservationResources.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const source_namespace = @import("proxy_observation.zig");
/// Creates a statically dispatched proxy-observation adapter.
///
/// ```zig
/// const ProxyObservationAdapter = Adapter(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericProxyObservationRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var adapter = ProxyObservationAdapter.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms successful proxy receives before validating their pane
        /// generation. Live inference events are translated into agent-domain
        /// evidence; receive failures and auxiliary traffic are discarded.
        ///
        /// ```zig
        /// try adapter.handle(receive_result);
        /// ```
        pub fn handle(adapter: *Self, result: anyerror!proxy_mod.Observation) !void {
            const event = result catch return;
            try port.rearm_receive(adapter.context);

            const pane = adapter.resources.panes.resolve(event.pane) orelse {
                adapter.resources.metrics.stale_pane_events += 1;
                return;
            };

            if (comptime source_namespace.diagnostics.enabled) {
                adapter.resources.metrics.proxy_observations +|= 1;
            }

            const observation = source_namespace.translate(event, pane) orelse return;
            _ = adapter.resources.agents.observeProxy(observation);
            port.schedule_description(adapter.context);
            port.pump_clients(adapter.context);
        }
    };
}
