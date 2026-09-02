//! Runtime-event adapter for asynchronous history responses.

const std = @import("std");
const history = @import("../../../history/root.zig");
const client_session = @import("../../client/root.zig").session;
const delivery_mod = @import("../../delivery/root.zig");
const runtime_event_entrypoints = @import("../../entrypoints/events/root.zig");
const event_sources = @import("../../event_sources.zig");

const ClientKey = client_session.Key;
const ClientSession = client_session.Session;
const ResponseQueue = delivery_mod.ResponseQueue;
const history_response_controller = runtime_event_entrypoints.history_response;

/// Binds history-response completions to one concrete Application type.
///
/// ```zig
/// const HistoryEvents = Dispatcher(Application);
/// ```
pub fn Dispatcher(comptime Application: type) type {
    return struct {
        /// Rearms the history response source, resolves its client and transfers
        /// the result into that client's bounded delivery queue.
        ///
        /// ```zig
        /// try HistoryEvents.handle(&application, result);
        /// ```
        pub fn handle(application: *Application, result: anyerror!history.Response) !void {
            var controller = historyResponseController(application);
            try controller.handle(result);
        }

        const history_response_runtime_port: history_response_controller.RuntimePort(Application, *ClientSession) = .{
            .rearm_receive = rearmHistoryResponse,
            .resolve = resolveHistoryResponseClient,
            .set_close_after_reply = setHistoryCloseAfterReply,
            .enqueue_query_result = enqueueHistoryQueryResult,
            .enqueue_failure = enqueueHistoryFailure,
            .enqueue_pruned = enqueueHistoryPruned,
            .dispose_query_result = disposeHistoryQueryResult,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeHistoryResponseController = history_response_controller.Controller(Application, *ClientSession, history_response_runtime_port);

        fn historyResponseController(application: *Application) RuntimeHistoryResponseController {
            return RuntimeHistoryResponseController.init(application);
        }

        fn rearmHistoryResponse(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.receiveHistory(application.history_service);
        }

        fn resolveHistoryResponseClient(application: *Application, client: ClientKey) ?*ClientSession {
            return application.clients.resolve(client);
        }

        fn setHistoryCloseAfterReply(_: *Application, session: *ClientSession, enabled: bool) void {
            session.delivery.setCloseAfterReply(enabled);
        }

        fn enqueueHistoryQueryResult(_: *Application, session: *ClientSession, result: *history.model.QueryResult) bool {
            session.delivery.responses.push(.{ .history_result = result }) catch return false;
            return true;
        }

        fn enqueueHistoryFailure(_: *Application, session: *ClientSession, failure: history.model.Failure) bool {
            queueFailure(&session.delivery.responses, .{
                .request_id = failure.request_id,
                .code = .internal,
                .message = failure.message,
            }) catch return false;
            return true;
        }

        fn enqueueHistoryPruned(_: *Application, session: *ClientSession, pruned: history.model.Pruned) bool {
            session.delivery.responses.push(.{ .history_pruned = .{
                .request_id = pruned.request_id,
                .removed = pruned.removed,
            } }) catch return false;
            return true;
        }

        fn disposeHistoryQueryResult(_: *Application, result: *history.model.QueryResult) void {
            result.deinit();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }

        fn queueFailure(responses: *ResponseQueue, failure: delivery_mod.PendingFailure) !void {
            try responses.push(.{ .request_failed = .{
                .request_id = failure.request_id,
                .code = failure.code,
                .message = failure.message,
            } });
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
