const GenericInputRuntimePort = @import("GenericInputRuntimePort.zig").Type;
const InputResources = @import("InputResources.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const InputWrite = @import("InputWrite.zig");
const enabled_module = @import("telar-core").enabled;
const now_module = @import("telar-core").now;
const InputCompletion = @import("InputCompletion.zig");
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const elapsed_module = @import("telar-core").elapsed;

/// Creates a statically dispatched input pump for one runtime context.
///
/// ```zig
/// const InputPump = Pump(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericInputRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: InputResources,

        /// Binds the pane repository and telemetry owned by one runtime.
        ///
        /// ```zig
        /// var pump = InputPump.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: InputResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one write for the pane. Async-start failure rolls
        /// back the borrow and preserves every queued byte for a later retry.
        ///
        /// ```zig
        /// try pump.schedule(pane);
        /// ```
        pub fn schedule(pump: *Self, pane: *PaneType) !void {
            const bytes = pane.beginPtyInputWrite() orelse return;
            const write: InputWrite = .{
                .io = pump.resources.io,
                .pane = pane,
                .bytes = bytes,
                .started_ns = if (comptime enabled_module) now_module(pump.resources.io) else 0,
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
        pub fn complete(pump: *Self, completion: InputCompletion) !void {
            const pane = pump.resources.panes.resolve(completion.pane) orelse {
                pump.resources.metrics.stale_pane_events += 1;
                return;
            };

            const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

            pane.completePtyInputWrite(result);

            if (comptime enabled_module) {
                pump.resources.metrics.input_write.observe(
                    elapsed_module(completion.started_ns, now_module(pump.resources.io)),
                );
            }

            if (result == .succeeded) {
                try pump.schedule(pane);
            }

            port.collect(pump.context);
        }
    };
}
