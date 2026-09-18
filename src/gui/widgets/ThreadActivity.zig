//! Compact tool rows and stable subagent cards share the same typed lifecycle.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const MessageText = @import("MessageText.zig");
const Activity = @This();

view: @import("ThreadItemView.zig"),

/// Measures the collapsed identity row and any explicitly expanded detail.
/// Example: `const height = try activity.measure(canvas);`
pub fn measure(activity: Activity, canvas: *Canvas) !f32 {
    var height = activity.headerHeight(canvas) + canvas.chrome.px(6);
    if (activity.view.expanded) {
        height += try activity.metadata(canvas).measure(canvas);
        if (activity.view.text().len > 0) {
            height += try activity.body(canvas).measure(canvas);
        }

        height += canvas.chrome.px(12);
    }

    return height;
}

/// Paints actual provider status and keeps child identity fixed across updates.
/// Example: `try activity.draw(canvas);`
pub fn draw(activity: Activity, canvas: *Canvas) !void {
    const view = activity.view;
    const palette = canvas.theme.palette;
    const child = view.item.kind == .subagent;
    const dispatch = view.item.kind == .dispatch;
    const inset = canvas.chrome.px(if (child) @as(f32, 12) else 4);
    const header: Rect = .{ .x = view.bounds.x, .y = view.bounds.y, .width = view.bounds.width, .height = activity.headerHeight(canvas) };
    if (child or view.expanded) {
        const card: Rect = .{ .x = view.bounds.x, .y = view.bounds.y, .width = view.bounds.width, .height = @max(0, view.bounds.height - canvas.chrome.px(6)) };
        const first = canvas.quads.items().len;
        try canvas.fillRoundedAt(card, .{ .color = palette.surface0, .radius = canvas.chrome.px(9) });
        canvas.quads.fadeFrom(first, if (child) @as(f32, 0.65) else 0.35);
        try canvas.ringAt(card, .{ .color = if (view.item.status == .failed) palette.red else palette.overlay0, .width = 1, .radius = canvas.chrome.px(9), .alpha = if (view.item.status == .failed) @as(f32, 0.5) else 0.35 });
    }

    const row = canvas.chrome.px(34);
    const icon_side = canvas.chrome.px(18);
    const icon_bounds: Rect = .{ .x = header.x + inset, .y = header.y + (row - icon_side) / 2, .width = icon_side, .height = icon_side };
    try canvas.iconAt(icon_bounds, .{ .text = activity.icon(), .face = .sans, .size = .body, .color = if (view.item.status == .failed) palette.red else palette.subtext0 });
    const status = activity.statusText();
    const status_width = @min(header.width * 0.3, try canvas.measure(.{ .text = status, .face = .sans, .size = .small }) + canvas.chrome.px(8));
    const chevron_width = if (activity.expandable()) canvas.chrome.px(22) else 0;
    const title_x = icon_bounds.x + icon_side + canvas.chrome.px(8);
    const title_bounds: Rect = .{ .x = title_x, .y = header.y, .width = @max(0, header.x + header.width - inset - status_width - chevron_width - title_x), .height = row };
    var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label: Label = .{ .text = activity.title(), .face = .sans, .size = .body, .bold = child or dispatch, .color = if (view.item.status == .failed) palette.red else if (child or dispatch) palette.text else palette.subtext0 };
    label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = title_bounds.width }).fit(label, &storage);
    try (@import("ActivityText.zig"){ .bounds = title_bounds, .label = label, .active = view.active() and title_bounds.y + title_bounds.height > view.viewport.y and title_bounds.y < view.viewport.y + view.viewport.height }).draw(canvas);
    const status_bounds: Rect = .{ .x = header.x + header.width - inset - status_width - chevron_width, .y = header.y, .width = status_width, .height = row };
    try activity.fitted(canvas, .{ .bounds = status_bounds, .label = .{ .text = status, .face = .sans, .size = .small, .color = activity.statusColor(canvas) } });
    if (activity.expandable()) {
        try canvas.iconAt(.{ .x = header.x + header.width - inset - chevron_width, .y = header.y, .width = chevron_width, .height = row }, .{ .text = if (view.expanded) "\u{f078}" else "\u{f054}", .face = .sans, .size = .small, .color = palette.overlay1 });
        var action_label: [240]u8 = undefined;
        const text = std.fmt.bufPrint(&action_label, "{s} {s}", .{ if (view.expanded) "Collapse" else "Expand", activity.title() }) catch "Expand activity";
        try (@import("ThreadItemButton.zig"){ .bounds = header, .viewport = view.viewport, .control = view.control(), .label = text }).register(canvas);
    }

    if (child) {
        const snapshot = view.thread.transcript.?;
        const detail = view.item.detail(snapshot);
        const preview = firstLine(view.text());
        const width = @max(0, header.x + header.width - inset - title_x);
        try activity.fitted(canvas, .{ .bounds = .{ .x = title_x, .y = header.y + row, .width = width, .height = canvas.chrome.px(22) }, .label = .{ .text = if (preview.len > 0) preview else status, .face = .sans, .size = .small, .color = if (view.item.status == .failed) palette.red else palette.subtext0 } });
        try activity.fitted(canvas, .{ .bounds = .{ .x = title_x, .y = header.y + row + canvas.chrome.px(22), .width = width, .height = canvas.chrome.px(22) }, .label = .{ .text = if (detail.len > 0) (if (view.active()) firstLine(detail) else lastLine(detail)) else view.item.reference(snapshot), .face = .sans, .size = .small, .color = palette.overlay1 } });
    } else if (dispatch) {
        var buffer: [80]u8 = undefined;
        const summary = activity.dispatchSummary(&buffer);
        try activity.fitted(canvas, .{ .bounds = .{ .x = title_x, .y = header.y + row, .width = @max(0, header.x + header.width - inset - title_x), .height = canvas.chrome.px(22) }, .label = .{ .text = summary, .face = .sans, .size = .small, .color = palette.overlay1 } });
    } else if (!view.expanded) {
        const detail = firstLine(view.item.detail(view.thread.transcript.?));
        if (detail.len > 0) {
            try activity.fitted(canvas, .{ .bounds = .{ .x = title_x, .y = header.y + row, .width = @max(0, header.x + header.width - inset - title_x), .height = canvas.chrome.px(22) }, .label = .{ .text = detail, .face = .sans, .size = .small, .color = palette.overlay1 } });
        }
    }

    if (view.expanded) {
        const detail_text = activity.metadata(canvas);
        try detail_text.draw(canvas);
        if (view.text().len > 0) {
            var content = activity.body(canvas);
            content.bounds.y += try detail_text.measure(canvas);
            try content.draw(canvas);
        }
    }
}

fn body(activity: Activity, canvas: *const Canvas) MessageText {
    const view = activity.view;
    const inset = @min(canvas.chrome.px(14), view.bounds.width / 8);
    const kind = view.item.kind;
    return .{ .bounds = .{ .x = view.bounds.x + inset, .y = view.bounds.y + activity.headerHeight(canvas), .width = @max(1, view.bounds.width - 2 * inset), .height = 0 }, .viewport = view.viewport, .text = view.text(), .muted = kind == .reasoning, .code = kind == .command or kind == .file_change or kind == .mcp or kind == .dynamic_tool, .diff = kind == .file_change, .markdown = kind != .system and view.item.fragment_start and view.item.fragment_end, .owner = view.source(.body) };
}

fn headerHeight(activity: Activity, canvas: *const Canvas) f32 {
    return canvas.chrome.px(if (activity.view.item.kind == .subagent) @as(f32, 84) else if (activity.view.item.kind == .dispatch or (!activity.view.expanded and activity.view.item.detail(activity.view.thread.transcript.?).len > 0)) 60 else 36);
}

fn expandable(activity: Activity) bool {
    return (activity.view.text().len > 0 or activity.view.item.detail(activity.view.thread.transcript.?).len > 0) and activity.view.item.identity != 0;
}

fn metadata(activity: Activity, canvas: *const Canvas) @import("ThreadDetails.zig") {
    return .{ .bounds = activity.body(canvas).bounds, .view = activity.view };
}

fn title(activity: Activity) []const u8 {
    if (activity.view.item.kind == .reasoning and activity.view.active()) {
        return "Thinking";
    }

    const provided = activity.view.item.title(activity.view.thread.transcript.?);
    if (provided.len > 0) {
        return provided;
    }

    return switch (activity.view.item.kind) {
        .reasoning => "Reasoning summary",
        .plan => "Plan",
        .command => "Run command",
        .file_change => "File changes",
        .mcp => "MCP tool",
        .dynamic_tool => "Tool call",
        .web_search => "Search the web",
        .dispatch => "Delegate tasks",
        .subagent => "Subagent",
        .system, .message => "Notice",
    };
}

fn icon(activity: Activity) []const u8 {
    return switch (activity.view.item.kind) {
        .reasoning => "\u{f0eb}",
        .plan => "\u{f03a}",
        .command => "\u{f120}",
        .file_change => "\u{f044}",
        .mcp, .dynamic_tool => "\u{f0ad}",
        .web_search => "\u{f002}",
        .dispatch => "\u{f0e8}",
        .subagent => "\u{f2bd}",
        .system, .message => "\u{f05a}",
    };
}

fn statusText(activity: Activity) []const u8 {
    if (!activity.view.item.fragment_start or !activity.view.item.fragment_end) {
        return "Continues";
    }
    return switch (activity.view.item.status) {
        .pending => "Queued",
        .running => "Working",
        .completed => "Done",
        .failed => "Failed",
        .interrupted => "Stopped",
        .declined => "Declined",
        .idle => "Idle",
        .closed => "Closed",
    };
}

fn statusColor(activity: Activity, canvas: *const Canvas) core.Color {
    return switch (activity.view.item.status) {
        .failed => canvas.theme.palette.red,
        .declined => canvas.theme.palette.yellow,
        .running, .pending => canvas.theme.palette.subtext0,
        .completed => canvas.theme.palette.teal,
        else => canvas.theme.palette.overlay1,
    };
}

fn dispatchSummary(activity: Activity, buffer: []u8) []const u8 {
    var total: usize = 0;
    var working: usize = 0;
    for (activity.view.thread.transcript.?.items()) |item| {
        if (item.kind == .subagent and item.parent_identity == activity.view.item.identity) {
            total += 1;
            if (item.status == .running or item.status == .pending) {
                working += 1;
            }
        }
    }

    if (total == 0) {
        return activity.view.item.detail(activity.view.thread.transcript.?);
    }

    return std.fmt.bufPrint(buffer, "{d} {s} · {d} working", .{ total, if (total == 1) "agent" else "agents", working }) catch "";
}

fn fitted(_: Activity, canvas: *Canvas, input: @import("ThreadLabelPaint.zig")) !void {
    var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label = input.label;
    label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = input.bounds.width }).fit(label, &storage);
    _ = try canvas.textAt(input.bounds, label);
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len];
}

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, "\r\n")) |index| index + 1 else 0;
    return trimmed[start..];
}
