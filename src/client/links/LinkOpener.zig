const data = @import("model");
/// Hands one owned link target to the host. The adapter reports completion
/// through its own event loop; the client owns the queue.
const LinkOpener = @This();

context: *anyopaque,
open: *const fn (*anyopaque, data.LinkTarget) anyerror!void,

/// Example: `try client.link_opener.start(target);`.
pub fn start(port: LinkOpener, target: data.LinkTarget) !void {
    return port.open(port.context, target);
}
