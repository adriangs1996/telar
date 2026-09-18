//! The visible conversation window owns no provider state or asynchronous work.
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Transcript = @This();

bounds: Rect,
thread: client.ThreadView,
request: ?*const core.AgentApprovalRequest = null,

/// Resolves proportional messages and compact activity into one scrollable column.
/// Example: `try transcript.draw(canvas);`
pub fn draw(widget: Transcript, source: *Canvas) !void {
    if (widget.bounds.width <= 0 or widget.bounds.height <= 0) {
        return;
    }

    var canvas = source.*;
    canvas.chrome.body = @intFromFloat(@max(6, @round(canvas.chrome.px(15))));
    canvas.chrome.title = @intFromFloat(@max(6, @round(canvas.chrome.px(18))));
    canvas.chrome.small = @intFromFloat(@max(6, @round(canvas.chrome.px(12))));
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, widget.bounds);
    if (widget.request) |request| {
        try widget.drawRequest(&canvas, request);
        return;
    }

    var flow: @import("ThreadFlow.zig") = .{ .bounds = widget.bounds, .thread = widget.thread };
    try flow.resolve(&canvas);
    if (canvas.widgets) |state| {
        const navigation = flow.navigation(widget.target(&canvas, flow.scroll_limit));
        _ = try state.dispatcher.add(navigation);
        if (canvas.animation) |clock| {
            state.thread_scroll.schedule(navigation, clock);
        }
    }
    if (flow.len == 0) {
        try widget.empty(&canvas);
        return;
    }

    try flow.draw(&canvas);
    if (widget.thread.history) |window| {
        if (!window.failed) {
            return;
        }
        var error_text: [320]u8 = undefined;
        const label = @import("std").fmt.bufPrint(&error_text, "{s} · scroll again to retry", .{window.failureMessage()}) catch window.failureMessage();
        const height = canvas.chrome.px(22);
        try canvas.fillAt(.{ .x = widget.bounds.x, .y = widget.bounds.y, .width = widget.bounds.width, .height = height }, canvas.theme.palette.surface_dim);
        _ = try canvas.textAt(.{ .x = widget.bounds.x, .y = widget.bounds.y, .width = widget.bounds.width, .height = height }, .{ .text = label, .face = .sans, .size = .small, .color = canvas.theme.palette.overlay1 });
    }
}

fn register(widget: Transcript, canvas: *Canvas, limit: f64) !void {
    if (canvas.widgets) |state| {
        const navigation = widget.target(canvas, limit);
        _ = try state.dispatcher.add(navigation);
        if (canvas.animation) |clock| {
            state.thread_scroll.schedule(navigation, clock);
        }
    }
}

fn target(widget: Transcript, canvas: *Canvas, limit: f64) @import("interaction/Target.zig") {
    return (@import("interaction/Target.zig"){ .id = .{ .generation = widget.thread.attachment_generation }, .bounds = widget.bounds, .action = .{ .transcript = widget.thread.pane_id }, .focusable = widget.request == null, .role = 6, .scroll_limit = limit, .scroll_step = canvas.chrome.px(24) }).labelled("Conversation");
}

fn drawRequest(widget: Transcript, canvas: *Canvas, request: *const core.AgentApprovalRequest) !void {
    var text: @import("MessageText.zig") = .{ .bounds = widget.bounds, .viewport = widget.bounds, .text = request.text(), .markdown = false };
    if (widget.thread.transcript) |snapshot| {
        text.owner = .{ .pane_id = widget.thread.pane_id, .attachment_generation = widget.thread.attachment_generation, .pane_generation = snapshot.pane_generation, .snapshot_revision = snapshot.revision, .item_identity = request.id, .section = .approval, .source_offset = 0 };
    }
    const height = try text.measure(canvas);
    const maximum = @max(0, height - widget.bounds.height);
    const limit: f64 = maximum / canvas.chrome.px(24);
    try widget.register(canvas, limit);
    text.bounds.y -= @max(0, maximum - @as(f32, @floatCast(@min(widget.thread.transcript_scroll, limit))) * canvas.chrome.px(24));
    try text.draw(canvas);
}

fn empty(widget: Transcript, canvas: *Canvas) !void {
    const area = widget.bounds;
    const height = @min(canvas.chrome.px(32), area.height / 2);
    const y = area.y + @max(0, (area.height - 2 * height) / 2);
    const labels = [_]@import("Label.zig"){
        .{ .text = "What would you like to build?", .face = .sans, .size = .title, .bold = true, .color = canvas.theme.palette.text },
        .{ .text = "Describe a task, ask a question, or explore your project.", .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 },
    };
    for (labels, 0..) |value, row| {
        var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
        var label = value;
        label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = area.width }).fit(value, &storage);
        _ = try canvas.textAt(.{ .x = area.x, .y = y + @as(f32, @floatFromInt(row)) * height, .width = area.width, .height = height }, label);
    }
}
