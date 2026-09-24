const ResponseHead = @import("ResponseHead.zig");

/// Creates the lifecycle runner for one intercepted HTTP/1.1 connection.
/// `Context` provides `readRequest() ?RequestHead`, `relayExchange(RequestHead)
/// ExchangeOutcome`, `publishRequest(RequestHead)`,
/// `publishResponse(ResponseHead)`, `publishFailure()` and `upgrade()`.
///
/// ```zig
/// const HttpConnection = GenericConnection(Context);
/// HttpConnection.run(&context);
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        /// Runs exchanges until input ends, an exchange fails, a response
        /// closes the connection, or a successful exchange upgrades it.
        /// Request publication always precedes its exchange; final response
        /// publication always precedes close or upgrade.
        ///
        /// ```zig
        /// HttpConnection.run(&context);
        /// ```
        pub fn run(context: *Context) void {
            while (context.readRequest()) |request| {
                context.publishRequest(request);

                switch (context.relayExchange(request)) {
                    .failed => {
                        context.publishFailure();
                        return;
                    },
                    .early_response => |response| {
                        if (!publishFinal(context, response)) {
                            return;
                        }

                        return;
                    },
                    .complete => |response| {
                        if (!publishFinal(context, response)) {
                            return;
                        }

                        switch (response.kind) {
                            .informational => unreachable,
                            .upgrade => {
                                context.upgrade();
                                return;
                            },
                            .final => if (response.connection == .close) {
                                return;
                            },
                        }
                    },
                }
            }
        }

        fn publishFinal(context: *Context, response: ResponseHead) bool {
            if (response.kind == .informational) {
                context.publishFailure();
                return false;
            }

            context.publishResponse(response);
            return true;
        }
    };
}
