const ThreadLayout = @import("ThreadLayout.zig");
const thread_status = @import("thread_status.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const ThreadPane = @This();

area: core.Rect,
thread: client.ThreadView,

/// Draws a native conversation with an attachment-scoped composer and controls.
/// Example: `try thread_pane.draw(canvas);`
pub fn draw(self: ThreadPane, canvas: *Canvas) !void {
    if (self.area.isEmpty()) {
        return;
    }

    if (self.thread.kind != .agent) {
        try self.drawTerminalThread(canvas);
        return;
    }

    const bounds = canvas.rect(self.area);
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, bounds);
    const palette = canvas.theme.palette;
    const approval = if (self.thread.transcript) |snapshot| snapshot.pending_approval else null;
    const layout = ThreadLayout.resolve(canvas, bounds, .{ .blocked = approval != null, .images = if (self.thread.composer_images) |images| images.count != 0 else false });
    const status = if (self.thread.transcript) |snapshot| snapshot.status else .starting;
    const status_text = thread_status.text(self.thread.transcript);
    const title = if (self.thread.agent) |agent| agent.displayName() else if (self.thread.kind == .agent) "Codex" else "Conversation";
    const header = layout.header;
    const status_width = @min(header.width / 2, try canvas.measure(.{ .text = status_text, .face = .sans, .size = .small }) + canvas.chrome.px(18));
    const resume_width = if (self.thread.transcript) |snapshot| if (snapshot.canResume()) @min(canvas.chrome.px(220), header.width * 0.55) else @as(f32, 0) else @as(f32, 0);
    if (resume_width > 0) {
        const recent = &self.thread.transcript.?.recent;
        const label: []const u8 = switch (recent.phase) {
            .loading => "Loading conversations…",
            .failed => "Conversations unavailable",
            .ready => if (recent.count == 0) "No recent conversations" else "Resume conversation…",
        };
        try (@import("ComposerTrigger.zig"){
            .bounds = .{ .x = header.x + header.width - status_width - resume_width, .y = header.y, .width = resume_width, .height = header.height },
            .selector = .{ .pane_id = self.thread.pane_id, .kind = .recent, .catalog_revision = self.thread.catalog_revision, .options_revision = self.thread.options_revision },
            .generation = self.thread.attachment_generation,
            .label = label,
            .enabled = recent.phase == .ready and recent.count > 0,
        }).draw(canvas);
    }

    _ = try canvas.textAt(.{ .x = header.x, .y = header.y, .width = @max(0, header.width - status_width - resume_width), .height = header.height }, .{ .text = title, .face = .sans, .size = .title, .bold = true, .color = palette.text });
    try (@import("ActivityText.zig"){ .bounds = .{ .x = header.x + header.width - status_width, .y = header.y, .width = status_width, .height = header.height }, .label = .{ .text = status_text, .face = .sans, .size = .small, .color = if (status == .blocked) palette.yellow else if (status == .failed) palette.red else palette.subtext0 }, .active = thread_status.active(self.thread.transcript) }).draw(canvas);
    var request: ?*const core.AgentApprovalRequest = null;
    if (canvas.widgets) |state| {
        if (state.approval_review) |review| {
            request = review.request(self.thread);
        }
    }

    try (@import("ThreadTranscript.zig"){ .bounds = layout.body, .thread = self.thread, .request = request }).draw(canvas);

    if (approval) |pending| {
        try self.drawApproval(canvas, .{ .bounds = layout.approval, .request = pending });
    }

    try (@import("AgentComposer.zig"){ .bounds = layout.composer, .pane_bounds = bounds, .thread = self.thread }).draw(canvas);
    try (@import("ThreadSelectionStatus.zig"){ .bounds = layout.footer, .pane_id = self.thread.pane_id }).draw(canvas);
}

fn drawTerminalThread(self: ThreadPane, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    try canvas.fill(self.area, palette.surface_dim);
    const header, const rest = self.area.splitTop(1);
    var storage: [256]u8 = undefined;
    const title = if (self.thread.agent) |agent| std.fmt.bufPrint(&storage, " {s} {s} · {s}", .{ agent.iconGlyph(), agent.displayName(), @tagName(agent.status) }) catch "Agent" else " no agent in this pane";
    try canvas.fill(header, palette.surface0);
    try canvas.text(header, .{ .text = title, .color = palette.accent, .bold = true });
    if (rest.isEmpty()) {
        return;
    }

    const body, const composer = rest.splitBottom(1);
    if (!body.isEmpty()) {
        const label = "No conversation available";
        const width = @min(body.w, core.measure(label));
        try canvas.text(.{ .x = body.x + (body.w - width) / 2, .y = body.y + body.h / 2, .w = width, .h = 1 }, .{ .text = label, .color = palette.subtext0 });
    }

    try canvas.fill(composer, palette.surface0);
    try canvas.text(composer.splitLeft(2)[0], .{ .text = "> ", .color = palette.accent });
    try canvas.text(composer.splitLeft(2)[1], .{ .text = if (self.thread.composer.len == 0) "write to the agent" else self.thread.composer, .color = if (self.thread.composer.len == 0) palette.overlay1 else palette.text });
}

fn drawApproval(self: ThreadPane, canvas: *Canvas, input: @import("ThreadApprovalPaint.zig")) !void {
    const area = input.bounds;
    const palette = canvas.theme.palette;
    const row = @min(canvas.chrome.px(28), area.height / 4);
    const inset = @min(canvas.chrome.px(12), area.width / 8);
    try canvas.fillRoundedAt(area, .{ .color = palette.surface0, .radius = canvas.chrome.px(8) });
    try canvas.ringAt(area, .{ .color = palette.yellow, .radius = canvas.chrome.px(8), .width = 1, .alpha = 0.6 });
    _ = try canvas.textAt(.{ .x = area.x + inset, .y = area.y, .width = area.width - 2 * inset, .height = row }, .{ .text = "Approval required · review the requested action in the conversation", .face = .sans, .size = .small, .bold = true, .color = palette.yellow });
    const columns: u16 = @intFromFloat(@max(1, @min(65535, @floor((area.width - 2 * inset) / @as(f32, @floatFromInt(canvas.metrics.cell_width))))));
    var lines: @import("overlays/WrappedLines.zig") = .{ .text = input.request.text(), .width = columns };
    for (0..2) |index| {
        const line = lines.next() orelse break;
        _ = try canvas.textAt(.{ .x = area.x + inset, .y = area.y + @as(f32, @floatFromInt(index + 1)) * row, .width = area.width - 2 * inset, .height = row }, .{ .text = line, .color = palette.text });
    }

    const width = @min(canvas.chrome.px(112), (area.width - 4 * inset) / 3);
    const y = area.y + area.height - row;
    try (@import("ThreadControl.zig"){ .bounds = .{ .x = area.x + inset, .y = y, .width = @max(0, area.width - 4 * inset - 2 * width), .height = row }, .pane_id = self.thread.pane_id, .generation = self.thread.attachment_generation, .kind = .review, .approval_id = input.request.id, .label = "Review full request" }).draw(canvas);
    try (@import("ThreadControl.zig"){ .bounds = .{ .x = area.x + area.width - inset - width, .y = y, .width = width, .height = row }, .pane_id = self.thread.pane_id, .generation = self.thread.attachment_generation, .kind = .approve, .approval_id = input.request.id, .label = "Approve" }).draw(canvas);
    try (@import("ThreadControl.zig"){ .bounds = .{ .x = area.x + area.width - 2 * inset - 2 * width, .y = y, .width = width, .height = row }, .pane_id = self.thread.pane_id, .generation = self.thread.attachment_generation, .kind = .decline, .approval_id = input.request.id, .label = "Decline" }).draw(canvas);
}
