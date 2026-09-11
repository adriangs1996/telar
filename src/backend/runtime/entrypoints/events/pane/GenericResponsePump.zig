const GenericResponseRuntimePort = @import("GenericResponseRuntimePort.zig").Type;
const Resources = @import("ResponseResources.zig");
const source_namespace = @import("response.zig");
const Write = @import("ResponseWrite.zig");
const Completion = @import("ResponseCompletion.zig");
const pane_mod = @import("../../../../pane/root.zig");
/// Creates a statically dispatched PTY response pump.
///
/// ```zig
/// const ResponsePump = Pump(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericResponseRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds the pane repository and runtime telemetry.
        ///
        /// ```zig
        /// var pump = ResponsePump.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one response write. Async-start failure releases the
        /// actor borrow while preserving the queue head for a retry.
        ///
        /// ```zig
        /// try pump.schedule(pane);
        /// ```
        pub fn schedule(pump: *Self, pane: *source_namespace.Pane) !void {
            const bytes = pane.beginPtyResponseWrite() orelse return;
            const write: Write = .{
                .io = pump.resources.io,
                .pane = pane,
                .bytes = bytes,
            };

            port.start(pump.context, write) catch |err| {
                pane.cancelPtyResponseWrite();
                return err;
            };
        }

        /// Applies one generation-matched completion. Success removes the
        /// written head and starts the next response; PTY failure clears the
        /// queue. Collection runs only after the pump reaches a settled state.
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

            pane.completePtyResponseWrite(result);

            if (result == .succeeded) {
                try pump.schedule(pane);
            }

            port.collect(pump.context);
        }
    };
}
