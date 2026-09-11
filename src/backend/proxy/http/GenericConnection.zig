const ResponseHeadType = @import("ResponseHead.zig");

/// Creates the lifecycle runner for one intercepted HTTP/1.1 connection.
///
/// ```zig
/// const HttpConnection = Connection(Context, port);
/// HttpConnection.run(&context);
/// ```
pub fn Type(comptime Context: type, comptime port: anytype) type {
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
            while (port.read_request(context)) |request| {
                port.publish_request(context, request);

                switch (port.exchange(context, request)) {
                    .failed => {
                        port.publish_failure(context);
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
                                port.upgrade(context);
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

        fn publishFinal(context: *Context, response: ResponseHeadType) bool {
            if (response.kind == .informational) {
                port.publish_failure(context);
                return false;
            }

            port.publish_response(context, response);
            return true;
        }
    };
}
