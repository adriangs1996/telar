const GenericSystemMetricsCoordinatorRuntimePort = @import("GenericSystemMetricsCoordinatorRuntimePort.zig").Type;
const Resources = @import("Resources.zig");
const system_metrics = @import("system_metrics.zig");
const std = @import("std");
/// Example: `const Metrics = Coordinator(Context, port);`.
pub fn Type(comptime Context: type, comptime port: GenericSystemMetricsCoordinatorRuntimePort(Context)) type {
    return struct {
        const Self = @This();
        context: *Context,
        resources: Resources,

        /// Example: `var coordinator = Metrics.init(&context, resources);`.
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Coalesces timer ticks while the worker owns a sampler copy.
        /// Example: `try coordinator.handle(tick_result);`.
        pub fn handle(coordinator: *Self, result: anyerror!void) !void {
            result catch return;
            try port.rearm_tick(coordinator.context);
            if (coordinator.resources.pending.*) {
                return;
            }

            coordinator.resources.pending.* = true;
            errdefer coordinator.resources.pending.* = false;
            try port.schedule(coordinator.context, coordinator.resources.sampler.*);
        }

        /// Publishes a complete sample; unchanged projections do not pump clients.
        /// Example: `coordinator.complete(sampled);`.
        pub fn complete(coordinator: *Self, sampled: system_metrics.Sampler) void {
            std.debug.assert(coordinator.resources.pending.*);
            const changed = sampled.revision != coordinator.resources.sampler.revision;
            coordinator.resources.pending.* = false;
            coordinator.resources.sampler.* = sampled;
            if (changed) {
                port.pump_clients(coordinator.context);
            }
        }
    };
}
