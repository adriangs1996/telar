const GenericInputRuntimePort = @import("GenericInputRuntimePort.zig").Type;
const Resources = @import("InputResources.zig");
const source_namespace = @import("input.zig");
const Write = @import("InputWrite.zig");
const Completion = @import("InputCompletion.zig");
const pane_mod = @import("../../../../pane/root.zig");
/// Creates a statically dispatched input pump for one runtime context.
///
/// ```zig
/// const InputPump = Pump(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericInputRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds the pane repository and telemetry owned by one runtime.
        ///
        /// ```zig
        /// var pump = InputPump.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one write for the pane. Async-start failure rolls
        /// back the borrow and preserves every queued byte for a later retry.
        ///
        /// ```zig
        /// try pump.schedule(pane);
        /// ```
        pub fn schedule(pump: *Self, pane: *source_namespace.Pane) !void {
            const bytes = pane.beginPtyInputWrite() orelse return;
            const write: Write = .{
                .io = pump.resources.io,
                .pane = pane,
                .bytes = bytes,
                .started_ns = if (comptime source_namespace.diagnostics.enabled) source_namespace.diagnostics.now(pump.resources.io) else 0,
            };

            port.start(pump.context, write) catch |err| {
                pane.cancelPtyInputWrite();
                return err;
            };
        }

        /// Applies exactly one completion to its generation-matched pane.
        /// Success consumes the borrowed prefix and schedules the backlog;
        /// PTY failure clears the queue. Collection runs after a settled pump.
        ///
        /// ```zig
        /// try pump.complete(completion);
        /// ```
        pub fn complete(pump: *Self, completion: Completion) !void {
            const pane = pump.resources.panes.resolve(completion.pane) orelse {
                pump.resources.metrics.stale_pane_events += 1;
                return;
            };

            const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

            pane.completePtyInputWrite(result);

            if (comptime source_namespace.diagnostics.enabled) {
                pump.resources.metrics.input_write.observe(
                    source_namespace.diagnostics.elapsed(completion.started_ns, source_namespace.diagnostics.now(pump.resources.io)),
                );
            }

            if (result == .succeeded) {
                try pump.schedule(pane);
            }

            port.collect(pump.context);
        }
    };
}
