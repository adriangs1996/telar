//! Searchable-history external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../history/root.zig");
const telemetry_mod = @import("../telemetry.zig");
const common = @import("common.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;

pub fn queryHistory(
    io: std.Io,
    service: *history_mod.Service,
    responses: *common.ResponseQueue,
    metrics: *telemetry_mod.RuntimeMetrics,
    origin: history_mod.model.QueryOrigin,
    request: schema.QueryHistory,
) !void {
    const query = history_mod.Query.init(
        request.request_id,
        origin,
        request.query,
        request.scope,
        request.scope_value,
        request.pane_id,
        request.failed_only,
        request.limit,
    ) catch {
        try common.queueFailure(
            responses,
            request.request_id,
            .invalid_request,
            "invalid history query",
        );
        return;
    };
    if (!service.query(io, query)) {
        if (comptime diagnostics.enabled) metrics.history_query_failures += 1;
        try common.queueFailure(
            responses,
            request.request_id,
            .resource_limit,
            "history queue is full",
        );
        return;
    }
    if (comptime diagnostics.enabled) metrics.history_queries += 1;
}
