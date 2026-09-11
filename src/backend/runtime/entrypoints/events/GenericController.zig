const GenericHistoryResponseRuntimePort = @import("GenericHistoryResponseRuntimePort.zig").Type;
const history = @import("../../../history/root.zig");
/// Creates a statically dispatched history-response controller.
///
/// ```zig
/// const HistoryResponseController = Controller(Context, Session, port);
/// ```
pub fn Type(comptime Context: type, comptime Session: type, comptime port: GenericHistoryResponseRuntimePort(Context, Session)) type {
    return struct {
        const Self = @This();

        context: *Context,

        /// Binds history response ownership and delivery to one runtime.
        ///
        /// ```zig
        /// var controller = HistoryResponseController.init(&context);
        /// ```
        pub fn init(context: *Context) Self {
            return .{ .context = context };
        }

        /// Rearms the worker response receive before routing the current value.
        /// Query results remain owned by this call until a client queue accepts
        /// them; stale routing, backpressure, and rearm failure dispose them.
        /// Worker receive failure ends the response stream without new effects.
        ///
        /// ```zig
        /// try controller.handle(response_result);
        /// ```
        pub fn handle(controller: *Self, response_result: anyerror!history.Response) !void {
            const response = response_result catch return;
            var owned_query: ?*history.model.QueryResult = switch (response) {
                .query_result => |result| result,
                .failed, .pruned, .output_result, .stats_result => null,
            };
            defer if (owned_query) |result| {
                port.dispose_query_result(controller.context, result);
            };
            var owned_output: ?*history.model.OutputResult = switch (response) {
                .output_result => |result| result,
                else => null,
            };
            defer if (owned_output) |result| {
                result.deinit();
            };
            var owned_stats: ?*history.model.StatsResult = switch (response) {
                .stats_result => |result| result,
                else => null,
            };
            defer if (owned_stats) |result| {
                result.deinit();
            };

            try port.rearm_receive(controller.context);

            switch (response) {
                .query_result => |result| {
                    const session = port.resolve(controller.context, result.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, result.origin.close_after_reply);

                    if (port.enqueue_query_result(controller.context, session, result)) {
                        owned_query = null;
                    } else {
                        port.dispose_query_result(controller.context, result);
                        owned_query = null;
                    }
                },
                .failed => |failure| {
                    const session = port.resolve(controller.context, failure.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, failure.origin.close_after_reply);
                    _ = port.enqueue_failure(controller.context, session, failure);
                },
                .pruned => |pruned| {
                    const session = port.resolve(controller.context, pruned.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, pruned.origin.close_after_reply);
                    _ = port.enqueue_pruned(controller.context, session, pruned);
                },
                .output_result => |result| {
                    const session = port.resolve(controller.context, result.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, result.origin.close_after_reply);
                    if (port.enqueue_output_result(controller.context, session, result)) {
                        owned_output = null;
                    }
                },
                .stats_result => |result| {
                    const session = port.resolve(controller.context, result.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, result.origin.close_after_reply);
                    if (port.enqueue_stats_result(controller.context, session, result)) {
                        owned_stats = null;
                    }
                },
            }

            port.pump_clients(controller.context);
        }
    };
}
