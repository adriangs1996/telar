const model_module = @import("../../../history/model.zig");
const GenericHistoryResponseRuntimePort = @import("../../entrypoints/events/GenericHistoryResponseRuntimePort.zig").Type;
const Session = @import("../../client/Session.zig");
const GenericController = @import("../../entrypoints/events/GenericController.zig").Type;
const SourcesType = @import("../../Sources.zig");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const QueryResultType = @import("../../../history/QueryResult.zig");
const FailureType = @import("../../../history/Failure.zig");
const StatsResultType = @import("../../../history/StatsResult.zig");
const OutputResultType = @import("../../../history/OutputResult.zig");
const PrunedType = @import("../../../history/Pruned.zig");
const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const PendingFailureType = @import("../../delivery/PendingFailure.zig");

/// Binds history-response completions to one concrete Application type.
///
/// ```zig
/// const HistoryEvents = Dispatcher(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        /// Rearms the history response source, resolves its client and transfers
        /// the result into that client's bounded delivery queue.
        ///
        /// ```zig
        /// try HistoryEvents.handle(&application, result);
        /// ```
        pub fn handle(application: *Application, result: anyerror!model_module.Response) !void {
            var controller = historyResponseController(application);
            try controller.handle(result);
        }

        const history_response_runtime_port: GenericHistoryResponseRuntimePort(Application, *Session) = .{
            .rearm_receive = rearmHistoryResponse,
            .resolve = resolveHistoryResponseClient,
            .set_close_after_reply = setHistoryCloseAfterReply,
            .enqueue_query_result = enqueueHistoryQueryResult,
            .enqueue_failure = enqueueHistoryFailure,
            .enqueue_pruned = enqueueHistoryPruned,
            .enqueue_output_result = enqueueHistoryOutputResult,
            .enqueue_stats_result = enqueueHistoryStatsResult,
            .dispose_query_result = disposeHistoryQueryResult,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeHistoryResponseController = GenericController(Application, *Session, history_response_runtime_port);

        fn historyResponseController(application: *Application) RuntimeHistoryResponseController {
            return RuntimeHistoryResponseController.init(application);
        }

        fn rearmHistoryResponse(application: *Application) !void {
            var sources = SourcesType.init(application.io, application.select);
            try sources.receiveHistory(application.history_service);
        }

        fn resolveHistoryResponseClient(application: *Application, client: ClientKeyType) ?*Session {
            return application.clients.resolve(client);
        }

        fn setHistoryCloseAfterReply(_: *Application, session: *Session, enabled: bool) void {
            session.delivery.setCloseAfterReply(enabled);
        }

        fn enqueueHistoryQueryResult(_: *Application, session: *Session, result: *QueryResultType) bool {
            session.delivery.responses.push(.{ .history_result = result }) catch return false;
            return true;
        }

        fn enqueueHistoryFailure(_: *Application, session: *Session, failure: FailureType) bool {
            queueFailure(&session.delivery.responses, .{
                .request_id = failure.request_id,
                .code = .internal,
                .message = failure.message,
            }) catch return false;
            return true;
        }

        fn enqueueHistoryStatsResult(_: *Application, session: *Session, result: *StatsResultType) bool {
            session.delivery.responses.push(.{ .history_stats = result }) catch return false;
            return true;
        }

        fn enqueueHistoryOutputResult(_: *Application, session: *Session, result: *OutputResultType) bool {
            session.delivery.responses.push(.{ .history_output = result }) catch return false;
            return true;
        }

        fn enqueueHistoryPruned(_: *Application, session: *Session, pruned: PrunedType) bool {
            session.delivery.responses.push(.{ .history_pruned = .{
                .request_id = pruned.request_id,
                .removed = pruned.removed,
            } }) catch return false;
            return true;
        }

        fn disposeHistoryQueryResult(_: *Application, result: *QueryResultType) void {
            result.deinit();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }

        fn queueFailure(responses: *ResponseQueueType, failure: PendingFailureType) !void {
            try responses.push(.{ .request_failed = .{
                .request_id = failure.request_id,
                .code = failure.code,
                .message = failure.message,
            } });
        }
    };
}
