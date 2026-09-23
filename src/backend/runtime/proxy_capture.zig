//! Each finished direction of an intercepted exchange arrives as one bounded
//! half; the runtime decodes it, joins it with its partner and submits the
//! whole exchange to the plugin tap. Traffic never waits for any of it.

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Half = @import("../proxy/capture/Half.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Sources = @import("Sources.zig");

/// Rearms the capture receive and joins one half for a live pane.
///
/// ```zig
/// try proxy_capture.receive(model, result);
/// ```
pub fn receive(model: *RuntimeModel, result: anyerror!*Half) !void {
    const half = result catch return;
    errdefer half.deinit();

    var sources = Sources.init(model.io, model.select);
    try sources.receiveProxyCapture(&model.resources.proxy);

    const key: PaneKey = .{ .id = half.pane.id, .generation = half.pane.generation };
    if (model.panes.resolve(key) == null) {
        half.deinit();
        return;
    }

    model.resources.proxy.decodeCapture(half);
    model.resources.proxy.acceptCapture(.{
        .now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        .half = half,
    });
}
