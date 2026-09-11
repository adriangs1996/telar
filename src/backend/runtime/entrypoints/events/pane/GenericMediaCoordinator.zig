const GenericMediaRuntimePort = @import("GenericMediaRuntimePort.zig").Type;
const Resources = @import("MediaResources.zig");
const source_namespace = @import("media.zig");
const Work = @import("MediaWork.zig");
const Completion = @import("MediaCompletion.zig");
const media_mod = @import("../../../../media/root.zig");
/// Creates a statically dispatched media coordinator.
///
/// ```zig
/// const MediaCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericMediaRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane repository and graphics telemetry.
        ///
        /// ```zig
        /// var coordinator = MediaCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one media actor. Async-start failure releases the
        /// pane and sealed-batch borrow.
        ///
        /// ```zig
        /// try coordinator.schedule(pane);
        /// ```
        pub fn schedule(coordinator: *Self, pane: *source_namespace.Pane) !void {
            const borrow = pane.beginMediaProcessing() orelse return;
            const work: Work = .{ .pane = pane, .current_size = borrow.current_size };

            port.start(coordinator.context, work) catch |err| {
                pane.cancelMediaProcessing();
                return err;
            };
        }

        /// Settles one generation-matched media batch, projects its bounded
        /// graphics state to clients, schedules PTY replies, then rearms any
        /// queued media work between the two client-pump opportunities.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: Completion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            pane.completeMediaProcessing();
            coordinator.observeMetrics(completion.stats);
            port.enforce_quotas(coordinator.context, pane);
            pane.refreshGraphicsProjection();

            const projection = port.synchronize_clients(coordinator.context, pane, completion.stats.reset);
            if (comptime source_namespace.diagnostics.enabled) {
                coordinator.resources.metrics.graphics_transfers_staged +|= projection.staged;
            }

            try port.schedule_response(coordinator.context, pane);
            port.pump_clients(coordinator.context);
            try coordinator.schedule(pane);
            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }

        fn observeMetrics(coordinator: *Self, stats: media_mod.Stats) void {
            if (comptime !source_namespace.diagnostics.enabled) {
                return;
            }

            coordinator.resources.metrics.media_bytes +|= stats.output_bytes;
            coordinator.resources.metrics.media_discarded_frames +|= stats.discarded_frames;
            coordinator.resources.metrics.media_unavailable_frames +|= stats.unavailable_frames;
            coordinator.resources.metrics.media_forwarded_frames +|= stats.forwarded_frames;
            coordinator.resources.metrics.graphics_transfers_prepared +|= stats.prepared_frames;
            coordinator.resources.metrics.media_direct_frames +|= stats.direct_frames;
            coordinator.resources.metrics.media_file_frames +|= stats.file_frames;
            coordinator.resources.metrics.media_ingest.observe(stats.elapsed_ns);

            if (stats.failed) {
                coordinator.resources.metrics.media_failures +|= 1;
            }

            if (stats.reset) {
                coordinator.resources.metrics.media_resets +|= 1;
            }
        }
    };
}
