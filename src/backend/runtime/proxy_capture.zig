//! Each finished direction of an intercepted exchange arrives as one bounded
//! half; the runtime decodes it, joins it with its partner and submits the
//! whole exchange to the plugin tap. Traffic never waits for any of it.

const owned = @import("../proxy/capture/owned.zig");
const limit_reached = @import("limit_reached.zig");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Half = owned.Half;
const Sources = @import("Sources.zig");

/// Rearms the capture receive and joins one half.
///
/// ```zig
/// try proxy_capture.receive(model, result);
/// ```
pub fn receive(model: *RuntimeModel, result: anyerror!*Half) !void {
    const half = result catch return;
    errdefer half.deinit();

    var sources = Sources.init(model.io, model.select);
    try sources.receiveProxyCapture(&model.resources.proxy);

    model.resources.proxy.decodeCapture(half, model.resources.pluginService());
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    switch (model.resources.proxy.acceptCapture(now_ms, half, model.resources.pluginService())) {
        .joined => {},
        .table_full => limit_reached.report(model, .{
            .limit = owned.joiner_capacity_limit,
        }),
    }
}
