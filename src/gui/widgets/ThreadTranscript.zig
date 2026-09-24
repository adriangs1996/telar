//! The visible conversation window owns no provider state or asynchronous work.
const std = @import("std");
const TextFit = @import("TextFit.zig");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ThreadFlow = @import("ThreadFlow.zig");
const Target = @import("interaction/Target.zig");
const MessageText = @import("MessageText.zig");
const Label = @import("Label.zig");
const Transcript = @This();

bounds: Rect,
thread: client.ThreadView,
request: ?*const core.AgentApprovalRequest = null,

/// Resolves proportional messages and compact activity into one scrollable column.
/// Example: `try transcript.draw(canvas);`
pub fn draw(self: Transcript, source: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    var canvas = source.*;
    canvas.chrome.body = @intFromFloat(@max(6, @round(canvas.chrome.px(15))));
    canvas.chrome.title = @intFromFloat(@max(6, @round(canvas.chrome.px(18))));
    canvas.chrome.small = @intFromFloat(@max(6, @round(canvas.chrome.px(12))));
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, self.bounds);
    if (self.request) |request| {
        try self.drawRequest(&canvas, request);
        return;
    }

    var flow: ThreadFlow = .{ .bounds = self.bounds, .thread = self.thread };
    try flow.resolve(&canvas);
    if (canvas.widgets) |state| {
        const navigation = flow.navigation(self.target(&canvas, flow.scroll_limit));
        _ = try state.dispatcher.add(navigation);
        if (canvas.animation) |clock| {
            state.thread_scroll.schedule(navigation, clock);
        }
    }
    if (flow.len == 0) {
        try self.empty(&canvas);
        return;
    }

    try flow.draw(&canvas);
    if (self.thread.history) |window| {
        if (!window.failed) {
            return;
        }
        var error_text: [320]u8 = undefined;
        const label = std.fmt.bufPrint(&error_text, "{s} · scroll again to retry", .{window.failureMessage()}) catch window.failureMessage();
        const height = canvas.chrome.px(22);
        try canvas.fillAt(.{ .x = self.bounds.x, .y = self.bounds.y, .width = self.bounds.width, .height = height }, canvas.theme.palette.surface_dim);
        _ = try canvas.textAt(.{ .x = self.bounds.x, .y = self.bounds.y, .width = self.bounds.width, .height = height }, .{ .text = label, .face = .sans, .size = .small, .color = canvas.theme.palette.overlay1 });
    }
}

fn register(self: Transcript, canvas: *Canvas, limit: f64) !void {
    if (canvas.widgets) |state| {
        const navigation = self.target(canvas, limit);
        _ = try state.dispatcher.add(navigation);
        if (canvas.animation) |clock| {
            state.thread_scroll.schedule(navigation, clock);
        }
    }
}

fn target(self: Transcript, canvas: *Canvas, limit: f64) Target {
    return (Target{ .id = .{ .generation = self.thread.attachment_generation }, .bounds = self.bounds, .action = .{ .transcript = self.thread.pane_id }, .focusable = self.request == null, .role = 6, .scroll_limit = limit, .scroll_step = canvas.chrome.px(24) }).labelled("Conversation");
}

fn drawRequest(self: Transcript, canvas: *Canvas, request: *const core.AgentApprovalRequest) !void {
    var text: MessageText = .{ .bounds = self.bounds, .viewport = self.bounds, .text = request.text(), .markdown = false };
    if (self.thread.transcript) |snapshot| {
        text.owner = .{ .pane_id = self.thread.pane_id, .attachment_generation = self.thread.attachment_generation, .pane_generation = snapshot.pane_generation, .snapshot_revision = snapshot.revision, .item_identity = request.id, .section = .approval, .source_offset = 0 };
    }
    const height = try text.measure(canvas);
    const maximum = @max(0, height - self.bounds.height);
    const limit: f64 = maximum / canvas.chrome.px(24);
    try self.register(canvas, limit);
    text.bounds.y -= @max(0, maximum - @as(f32, @floatCast(@min(self.thread.transcript_scroll, limit))) * canvas.chrome.px(24));
    try text.draw(canvas);
}

fn empty(self: Transcript, canvas: *Canvas) !void {
    const area = self.bounds;
    const height = @min(canvas.chrome.px(32), area.height / 2);
    const y = area.y + @max(0, (area.height - 2 * height) / 2);
    const labels = [_]Label{
        .{ .text = "What would you like to build?", .face = .sans, .size = .title, .bold = true, .color = canvas.theme.palette.text },
        .{ .text = "Describe a task, ask a question, or explore your project.", .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 },
    };
    for (labels, 0..) |value, row| {
        var storage: [TextFit.max_bytes]u8 = undefined;
        var label = value;
        label.text = try (TextFit{ .canvas = canvas, .width = area.width }).fit(value, &storage);
        _ = try canvas.textAt(.{ .x = area.x, .y = y + @as(f32, @floatFromInt(row)) * height, .width = area.width, .height = height }, label);
    }
}
