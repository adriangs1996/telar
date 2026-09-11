const GenericIngestRuntimePort = @import("GenericIngestRuntimePort.zig").Type;
const IngestResources = @import("IngestResources.zig");
const IngestCompletion = @import("IngestCompletion.zig");
const enabled_module = @import("telar-core").enabled;
const Read = @import("Read.zig");
const std = @import("std");

/// Creates a statically dispatched post-ingest coordinator.
///
/// ```zig
/// const IngestCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericIngestRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: IngestResources,

        /// Binds one runtime's pane repository and telemetry.
        ///
        /// ```zig
        /// var coordinator = IngestCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: IngestResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Settles one generation-matched ingest. Success synchronizes domain,
        /// background observers, client projections, PTY responses, and the
        /// next read in that order. Ingest failure retires the pane output.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: IngestCompletion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            pane.completeOutputIngest();
            const stats = completion.result catch {
                _ = pane.requestClose();
                pane.finishPtyOutput();
                port.collect(coordinator.context);
                return;
            };

            if (comptime enabled_module) {
                coordinator.resources.metrics.ingest.observe(stats.elapsed_ns);
            }

            pane.applyPendingResize() catch {
                _ = pane.requestClose();
            };
            try port.schedule_observation(coordinator.context, pane);
            try port.schedule_media(coordinator.context, pane);
            port.refresh_clients(coordinator.context, pane);
            try port.schedule_response(coordinator.context, pane);

            const read: Read = .{
                .io = coordinator.resources.io,
                .pane = pane,
            };
            const read_started = pane.beginPtyOutputRead();
            std.debug.assert(read_started);
            port.start_read(coordinator.context, read) catch |err| {
                pane.cancelPtyOutputRead();
                return err;
            };

            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }
    };
}
