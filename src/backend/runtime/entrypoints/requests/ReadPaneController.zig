const Controller = @This();
const source_namespace = @import("read_pane.zig");
responses: *source_namespace.ResponseQueue,

/// Creates one controller bound to the requesting client's responses.
///
/// ```zig
/// var controller = Controller.init(&responses);
/// ```
pub fn init(responses: *source_namespace.ResponseQueue) Controller {
    return .{ .responses = responses };
}

/// Queues one late-bound text read for the exact pane generation.
///
/// ```zig
/// try controller.readPane(request);
/// ```
pub fn readPane(controller: *Controller, request: source_namespace.schema.ReadPane) !void {
    try controller.responses.push(.{ .pane_text = .{
        .request_id = request.request_id,
        .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
        .rows = request.rows,
        .source = request.source,
    } });
}
