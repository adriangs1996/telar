const GenericOutputRuntimePort = @import("GenericOutputRuntimePort.zig").Type;
const OutputResources = @import("OutputResources.zig");
const OutputCompletion = @import("OutputCompletion.zig");
const enabled_module = @import("telar-core").enabled;
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const OutputIngest = @import("OutputIngest.zig");
const PaneType = @import("../../../../pane/Pane.zig");

/// Creates a statically dispatched PTY output pipeline.
///
/// ```zig
/// const OutputPipeline = Pipeline(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericOutputRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: OutputResources,

        /// Binds one runtime's pane repository and telemetry.
        ///
        /// ```zig
        /// var pipeline = OutputPipeline.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: OutputResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Completes one read. EOF/error settles the output lifecycle; data is
        /// copied into observation/media queues before its buffer is borrowed
        /// by the VT ingest actor. Scheduler errors cross unchanged.
        ///
        /// ```zig
        /// try pipeline.handle(completion);
        /// ```
        pub fn handle(pipeline: *Self, completion: OutputCompletion) !void {
            const pane = pipeline.resources.panes.resolve(completion.pane) orelse {
                pipeline.resources.metrics.stale_pane_events += 1;
                return;
            };
            const output_len = completion.result catch {
                pane.completePtyOutputRead(.finished);
                return pipeline.finishOutput(pane);
            };

            if (output_len == 0) {
                pane.completePtyOutputRead(.finished);
                return pipeline.finishOutput(pane);
            }

            pane.completePtyOutputRead(.data);

            if (comptime enabled_module) {
                pipeline.resources.metrics.pty_events += 1;
                pipeline.resources.metrics.pty_bytes += output_len;

                if (port.has_outstanding_frame(pipeline.context, pane.id)) {
                    pipeline.resources.metrics.folded_pty_events += 1;
                }
            }

            const bytes = pane.output_buffer[0..output_len];
            const shell_foreground = pane.session.shellForeground();
            pane.expireProgress(shell_foreground orelse false);
            pane.queueHistoryOutput(.{
                .bytes = bytes,
                .shell_foreground = shell_foreground,
                .clock = pane_mod.historyClock(pipeline.resources.io),
            });
            try port.schedule_observation(pipeline.context, pane);

            pane.queueMediaOutput(bytes);
            try port.schedule_media(pipeline.context, pane);

            const ingest: OutputIngest = .{
                .io = pipeline.resources.io,
                .pane = pane,
                .bytes = pane.beginOutputIngest(output_len),
            };
            port.start_ingest(pipeline.context, ingest) catch |err| {
                pane.cancelOutputIngest();
                return err;
            };
        }

        fn finishOutput(pipeline: *Self, pane: *PaneType) !void {
            if (pane.exit) |exit| {
                pane.queueExitedHistory(exit);
                try port.schedule_observation(pipeline.context, pane);
            }

            port.collect(pipeline.context);
            port.pump_clients(pipeline.context);
        }
    };
}
