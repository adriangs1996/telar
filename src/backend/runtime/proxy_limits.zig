//! Limits the proxy and its tap reach on their own threads. Their workers
//! only count; once a second the maintenance tick reports, on the event
//! loop, every limit whose count grew since the last tick. Traffic never
//! waits for a report.
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const limit_reached = @import("limit_reached.zig");
const Connections = @import("../proxy/Connections.zig");
const Http1Connection = @import("../proxy/tunnel/Http1Connection.zig");
const CaptureStreams = @import("../proxy/tunnel/CaptureStreams.zig");
const RelayContext = @import("../proxy/tunnel/RelayContext.zig");
const Tunnel = @import("../proxy/tunnel/Tunnel.zig");
const capture_queue = @import("../proxy/capture/queue.zig");
const plugins_support = @import("../plugins/service_support.zig");
const exchangecapture = @import("exchangecapture");
const std = @import("std");
const Snapshot = @import("../proxy/Snapshot.zig");
const TapLimitCounts = @import("../plugins/TapLimitCounts.zig");
const RequestFixture = @import("tests/RequestFixture.zig");
const CaptureConfig = exchangecapture.Config;
const proxy_service = @import("../proxy/service/service_support.zig");

/// Reports every proxy and tap limit reached since the last call.
///
/// ```zig
/// proxy_limits.report(model);
/// ```
pub fn report(model: *RuntimeModel) void {
    const proxy = &model.resources.proxy;
    const proxy_counts = proxy.metrics();
    reportProxy(model, proxy_counts, proxy.reported, proxy.captureConfig());
    proxy.reported = proxy_counts;

    const tap_counts = model.resources.pluginService().limitCounts();
    reportTap(model, tap_counts, proxy.tap_reported);
    proxy.tap_reported = tap_counts;
}

fn reportProxy(model: *RuntimeModel, now: Snapshot, last: Snapshot, capture: CaptureConfig) void {
    reportGrowth(model, now.connection_limit_drops, last.connection_limit_drops, proxy_service.connections_limit);
    reportGrowth(model, now.evictions, last.evictions, proxy_service.connections_limit);
    reportGrowth(model, now.unauthenticated_refusals, last.unauthenticated_refusals, Connections.unauthenticated_limit);
    reportGrowth(model, now.unauthenticated_evictions, last.unauthenticated_evictions, Connections.unauthenticated_limit);
    reportGrowth(model, now.connect_heads_too_large, last.connect_heads_too_large, Tunnel.connect_head_limit);
    reportGrowth(model, now.connect_head_timeouts, last.connect_head_timeouts, Connections.connect_head_timeout_limit);
    reportGrowth(model, now.establish_timeouts, last.establish_timeouts, Connections.establish_timeout_limit);
    reportGrowth(model, now.http1_heads_too_large, last.http1_heads_too_large, Http1Connection.head_limit);
    reportGrowth(model, now.http1_chunk_lines_too_long, last.http1_chunk_lines_too_long, Http1Connection.chunk_line_limit);
    reportGrowth(model, now.http1_trailer_lines_too_long, last.http1_trailer_lines_too_long, Http1Connection.trailer_line_limit);
    reportGrowth(model, now.h2_capture_streams_skipped, last.h2_capture_streams_skipped, CaptureStreams.capacity_limit);
    reportGrowth(model, now.h2_header_blocks_too_large, last.h2_header_blocks_too_large, RelayContext.header_block_limit);
    reportGrowth(model, now.h2_streams_untracked, last.h2_streams_untracked, RelayContext.tracked_streams_limit);
    reportGrowth(model, now.capture_dropped_queue, last.capture_dropped_queue, capture_queue.capacity_limit);
    reportGrowth(model, now.capture_truncated_part, last.capture_truncated_part, core.Limit.declare("proxy.capture.max_part_bytes", "bytes", capture.max_part_bytes));
    reportGrowth(model, now.capture_truncated_exchange, last.capture_truncated_exchange, core.Limit.declare("proxy.capture.max_exchange_bytes", "bytes", capture.max_exchange_bytes));
    reportGrowth(model, now.capture_truncated_total, last.capture_truncated_total, core.Limit.declare("proxy.capture.max_total_bytes", "bytes", capture.max_total_bytes));
}

fn reportTap(model: *RuntimeModel, now: TapLimitCounts, last: TapLimitCounts) void {
    reportGrowth(model, now.dropped_queue, last.dropped_queue, plugins_support.queue_depth_limit);
    reportGrowth(model, now.dropped_bytes, last.dropped_bytes, plugins_support.held_bytes_limit);
    reportGrowth(model, now.timeouts, last.timeouts, plugins_support.reply_timeout_limit);
    reportGrowth(model, now.disabled, last.disabled, plugins_support.restart_limit_reach);
}

/// Reports `limit` once when its counter grew since the last tick; the
/// notice itself is paced per limit by `limit_reached`.
fn reportGrowth(model: *RuntimeModel, now: u64, last: u64, limit: core.Limit) void {
    if (now > last) {
        limit_reached.report(model, .{
            .limit = limit,
        });
    }
}

test "a proxy counter that grew reports its limit by name, and an unchanged one does not" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;

    reportProxy(
        model,
        .{
            .connection_limit_drops = 3,
        },
        .{
            .connection_limit_drops = 1,
        },
        .{},
    );
    const slot = model.limit_reaches.find("proxy.max_connections").?;
    try std.testing.expectEqual(@as(u64, 1), model.limit_reaches.hits[slot]);

    const notice = fixture.response().?.notification.view();
    try std.testing.expectEqualStrings("proxy.max_connections: limit 256 connections reached", notice.message);

    reportProxy(
        model,
        .{
            .connection_limit_drops = 3,
        },
        .{
            .connection_limit_drops = 3,
        },
        .{},
    );
    try std.testing.expectEqual(@as(u64, 1), model.limit_reaches.hits[slot]);
}

test "capture truncation names the configured bound that cut it" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;

    reportProxy(
        model,
        .{
            .capture_truncated_total = 1,
        },
        .{},
        .{
            .max_total_bytes = 1024,
        },
    );
    try std.testing.expect(model.limit_reaches.find("proxy.capture.max_part_bytes") == null);

    const notice = fixture.response().?.notification.view();
    try std.testing.expectEqualStrings("proxy.capture.max_total_bytes: limit 1024 bytes reached", notice.message);
}

test "a tap worker disabled after its restarts is reported" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;

    reportTap(
        model,
        .{
            .disabled = 1,
            .timeouts = 5,
        },
        .{},
    );
    try std.testing.expect(model.limit_reaches.find("plugins.tap.restart_limit") != null);
    try std.testing.expect(model.limit_reaches.find("plugins.tap.reply_timeout_ms") != null);
    try std.testing.expect(model.limit_reaches.find("plugins.tap.queue_depth") == null);
}

test "the maintenance report of an idle proxy reports nothing" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;

    report(model);
    try std.testing.expectEqual(@as(usize, 0), model.limit_reaches.count);
}
