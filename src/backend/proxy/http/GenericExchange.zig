const RequestHeadType = @import("RequestHead.zig");
const connection = @import("connection.zig");
const std = @import("std");
const ExchangeState = @import("ExchangeState.zig");
const types = @import("types.zig");
const ResponseHeadType = @import("ResponseHead.zig");

/// Creates the executor for one HTTP/1.1 exchange.
///
/// ```zig
/// const RelayExchange = Exchange(Context, exchange_port);
/// const outcome = RelayExchange.execute(&context, request);
/// ```
pub fn Type(comptime Context: type, comptime port: anytype) type {
    return struct {
        /// Relays a bodyless response synchronously. When a request has a body,
        /// the upload and response race so an origin may reject the upload
        /// early. Every unfinished task is cancelled before returning.
        ///
        /// ```zig
        /// const outcome = RelayExchange.execute(&context, request);
        /// ```
        pub fn execute(context: *Context, request: RequestHeadType) connection.ExchangeOutcome {
            if (!request.body.hasBody()) {
                const response = port.relay_response(context, request) orelse return .failed;
                return .{ .complete = response };
            }

            const io = port.io(context);
            var event_storage: [2]connection.Event = undefined;
            var workers = std.Io.Select(connection.Event).init(io, &event_storage);
            workers.concurrent(.request_body, relayBody, .{ context, request.body }) catch return .failed;
            workers.concurrent(.response, relayResponse, .{ context, request }) catch {
                workers.cancelDiscard();
                return .failed;
            };
            defer workers.cancelDiscard();

            var state: ExchangeState = .{};

            while (true) {
                const event = workers.await() catch return .failed;

                if (state.accept(event)) |outcome| {
                    return outcome;
                }
            }
        }

        fn relayBody(context: *Context, body: types.BodyPlan) bool {
            return port.relay_body(context, body);
        }

        fn relayResponse(context: *Context, request: RequestHeadType) ?ResponseHeadType {
            return port.relay_response(context, request);
        }
    };
}
