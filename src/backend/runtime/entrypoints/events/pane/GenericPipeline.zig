const GenericOutputRuntimePort = @import("GenericOutputRuntimePort.zig").Type;
const Resources = @import("OutputResources.zig");
const Completion = @import("OutputCompletion.zig");
const source_namespace = @import("output.zig");
const pane_mod = @import("../../../../pane/root.zig");
const Ingest = @import("OutputIngest.zig");
/// Creates a statically dispatched PTY output pipeline.
///
/// ```zig
/// const OutputPipeline = Pipeline(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericOutputRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane repository and telemetry.
        ///
        /// ```zig
        /// var pipeline = OutputPipeline.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Completes one read. EOF/error settles the output lifecycle; data is
        /// copied into observation/media queues before its buffer is borrowed
        /// by the VT ingest actor. Scheduler errors cross unchanged.
        ///
        /// ```zig
        /// try pipeline.handle(completion);
        /// ```
        pub fn handle(pipeline: *Self, completion: Completion) !void {
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

            if (comptime source_namespace.diagnostics.enabled) {
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

            const ingest: Ingest = .{
                .io = pipeline.resources.io,
                .pane = pane,
                .bytes = pane.beginOutputIngest(output_len),
            };
            port.start_ingest(pipeline.context, ingest) catch |err| {
                pane.cancelOutputIngest();
                return err;
            };
        }

        fn finishOutput(pipeline: *Self, pane: *source_namespace.Pane) !void {
            if (pane.exit) |exit| {
                pane.queueExitedHistory(exit);
                try port.schedule_observation(pipeline.context, pane);
            }

            port.collect(pipeline.context);
            port.pump_clients(pipeline.context);
        }
    };
}
