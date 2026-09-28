const std = @import("std");
const Stats = @import("Stats.zig");

/// Creates the lifecycle owner for one intercepted HTTP/2 connection.
/// `Context` provides `relayRequest() Stats`, `relayResponse() Stats`,
/// `recordDecodeFailure(Direction)` and `settle()`.
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

            context.settle();
        }

        fn relayRequest(context: *Context) Stats {
            return context.relayRequest();
        }
    };
}
