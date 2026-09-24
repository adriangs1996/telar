//! Each finished direction of an intercepted exchange arrives as one bounded
//! half; the runtime decodes it, joins it with its partner and submits the
//! whole exchange to the plugin tap. Traffic never waits for any of it.

const owned = @import("../proxy/capture/owned.zig");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Half = owned.Half;
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

    const key: PaneKey = .{ .id = half.meta.pane.id, .generation = half.meta.pane.generation };
    if (model.panes.resolve(key) == null) {
        half.deinit();
        return;
    }

    model.resources.proxy.decodeCapture(half);
    model.resources.proxy.acceptCapture(std.Io.Timestamp.now(model.io, .real).toMilliseconds(), half, model.resources.pluginService());
}
