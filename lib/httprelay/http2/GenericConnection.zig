const std = @import("std");
const Stats = @import("Stats.zig");
const observer_hooks = @import("../observer_hooks.zig");

/// Creates the lifecycle owner for one intercepted HTTP/2 connection.
/// `Context` provides `relayRequest() Stats`, `relayResponse() Stats`,
/// `recordDecodeFailure(Direction)` and `settle()`, and may declare
/// `recordLimits(Direction, Stats)` to hear the bounds that cut observation.
///
/// ```zig
/// const RelayConnection = GenericConnection(Context);
/// RelayConnection.run(io, &context);
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        /// Relays requests concurrently while the response direction owns the
        /// connection lifetime. Once responses end, it cancels the request
        /// relay, records each failed decoder, then settles all open streams.
        ///
        /// ```zig
        /// RelayConnection.run(io, &context);
        /// ```
        pub fn run(io: std.Io, context: *Context) void {
            var request = io.concurrent(relayRequest, .{context}) catch {
                context.settle();
                return;
            };
            const response_stats = context.relayResponse();
            const request_stats = request.cancel(io);

            if (response_stats.decode_failed) {
                context.recordDecodeFailure(.response);
            }

            if (request_stats.decode_failed) {
                context.recordDecodeFailure(.request);
            }

            if (comptime observer_hooks.declares(*Context, "recordLimits")) {
                context.recordLimits(.response, response_stats);
                context.recordLimits(.request, request_stats);
            }

            context.settle();
        }

        fn relayRequest(context: *Context) Stats {
            return context.relayRequest();
        }
    };
}
