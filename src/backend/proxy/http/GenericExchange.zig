const RequestHead = @import("RequestHead.zig");
const connection = @import("connection.zig");
const std = @import("std");
const ExchangeState = @import("ExchangeState.zig");
const types = @import("types.zig");
const ResponseHead = @import("ResponseHead.zig");

/// Creates the executor for one HTTP/1.1 exchange. `Context` provides
/// `relayRequestBody(BodyPlan) bool` and `relayResponse(RequestHead)
/// ?ResponseHead`.
///
/// ```zig
/// const RelayExchange = GenericExchange(Context);
/// const outcome = RelayExchange.execute(io, &context, request);
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        /// Relays a bodyless response synchronously. When a request has a body,
        /// the upload and response race so an origin may reject the upload
        /// early. Every unfinished task is cancelled before returning.
        ///
        /// ```zig
        /// const outcome = RelayExchange.execute(io, &context, request);
        /// ```
        pub fn execute(io: std.Io, context: *Context, request: RequestHead) connection.ExchangeOutcome {
            if (!request.body.hasBody()) {
                const response = context.relayResponse(request) orelse return .failed;
                return .{ .complete = response };
            }

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
            return context.relayRequestBody(body);
        }

        fn relayResponse(context: *Context, request: RequestHead) ?ResponseHead {
            return context.relayResponse(request);
        }
    };
}
