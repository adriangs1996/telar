const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ReadPaneType = @import("telar-core").ReadPane;
const Controller = @This();

responses: *ResponseQueueType,

/// Creates one controller bound to the requesting client's responses.
///
/// ```zig
/// var controller = Controller.init(&responses);
/// ```
pub fn init(responses: *ResponseQueueType) Controller {
    return .{ .responses = responses };
}

/// Queues one late-bound text read for the exact pane generation.
///
/// ```zig
/// try controller.readPane(request);
/// ```
pub fn readPane(controller: *Controller, request: ReadPaneType) !void {
    try controller.responses.push(.{ .pane_text = .{
        .request_id = request.request_id,
        .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
        .rows = request.rows,
        .source = request.source,
    } });
}
