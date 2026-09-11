const GenericConnectionPort = @import("GenericConnectionPort.zig").Type;
const Settings = @import("Settings.zig");
const StatsType = @import("Stats.zig");

/// Creates the lifecycle owner for one intercepted HTTP/2 connection.
///
/// ```zig
/// const RelayConnection = Connection(Context, connection_port);
/// RelayConnection.run(&context);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericConnectionPort(Context)) type {
    return struct {
        /// Relays requests concurrently while the response direction owns the
        /// connection lifetime. Once responses end, it cancels the request
        /// relay, records each failed decoder, then settles all open streams.
        ///
        /// ```zig
        /// RelayConnection.run(&context);
        /// ```
        pub fn run(context: *Context) void {
            var settings: Settings = .{};
            const io = port.io(context);
            var request = io.concurrent(relayRequest, .{ context, &settings }) catch {
                port.settle(context);
                return;
            };
            const response_stats = port.relay_response(context, &settings);
            const request_stats = request.cancel(io);

            if (response_stats.decode_failed) {
                port.record_decode_failure(context, .response);
            }

            if (request_stats.decode_failed) {
                port.record_decode_failure(context, .request);
            }

            port.settle(context);
        }

        fn relayRequest(context: *Context, settings: *Settings) StatsType {
            return port.relay_request(context, settings);
        }
    };
}
