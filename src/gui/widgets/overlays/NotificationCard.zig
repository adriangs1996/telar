//! One native card. Text and semantic state are borrowed only while drawing.
const cellgrid = @import("cellgrid");
const shared_model = @import("model");
const core = @import("telar-core");
const std = @import("std");
const Canvas = @import("../Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Label = @import("../Label.zig");
const TextFit = @import("../TextFit.zig");
const Target = @import("../interaction/Target.zig");
const Hits = @import("NotificationHits.zig");
const Text = @import("NotificationText.zig");
const Card = @This();

/// Room for "Open …HOST ↗"; a host is at most a link's length.
const link_label_bytes = 16 + core.max_notification_link_bytes;
/// The screen-reader label's words beside the title, link host and message.
const accessible_label_bytes = core.max_notification_title_bytes + core.max_notification_link_bytes + core.max_notification_message_bytes + ", opens : ".len;

item: *const shared_model.NotificationItem,
bounds: Rect,
body: Text = .{},
opacity: f32 = 1,
clip: Rect,
hits: ?*Hits = null,

/// Measures the body once so drawing and input share the same pixel layout.
/// Example: `try card.measure(canvas);`
pub fn measure(self: *Card, canvas: *Canvas) !void {
    const text_width = self.bounds.width - canvas.chrome.px(76);
    try self.body.wrap(canvas, .{ .text = self.item.message(), .width = text_width });
    self.bounds.height = canvas.chrome.px(28) + canvas.chrome.rowHeight(.title);
    if (self.body.count > 0) {
        self.bounds.height += canvas.chrome.px(4) + @as(f32, @floatFromInt(self.body.count)) * canvas.chrome.rowHeight(.body);
    }
    if (self.item.clickable()) {
        self.bounds.height += canvas.chrome.px(10) + canvas.chrome.rowHeight(.small);
    }

    self.bounds.height = @max(self.bounds.height, canvas.chrome.px(64));
}

/// Paints and registers exactly the same bounds, with the close control last.
/// Example: `try card.draw(canvas);`
pub fn draw(self: *const Card, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const bounds = self.bounds;
    const radius = px.px(12);
    const accent = self.accentColor(canvas);
    for (0..3) |layer| {
        const spread = px.px(@as(f32, @floatFromInt(3 - layer)) * 2);
        try canvas.quads.pushRounded(.{ .x = bounds.x - spread, .y = bounds.y - spread + px.px(3), .width = bounds.width + 2 * spread, .height = bounds.height + 2 * spread }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.055 }, .radius = radius + spread });
    }

    try canvas.fillRoundedAt(bounds, .{ .color = canvas.covering(palette.surface0), .radius = radius });
    try canvas.ringAt(bounds, .{ .color = palette.overlay0, .width = px.px(1), .radius = radius, .alpha = 0.35 });

    var target = (Target{ .bounds = bounds, .action = .{ .intent = .{ .notification_activate = self.item.id } }, .enabled = self.item.phase != .exiting }).labelled(self.item.title());
    if (!self.item.clickable()) {
        target.action = .{ .intent = .{ .notification_dismiss = self.item.id } };
    }
    // Body and close can share a dismiss action, so use distinct namespaces.
    target.namespace = 2;
    // Room for the longest title, link and message a notification holds, so
    // the label always formats; `labelled` then keeps the prefix that fits.
    var accessible: [accessible_label_bytes]u8 = undefined;
    const label = if (self.item.link_len != 0)
        std.fmt.bufPrint(&accessible, "{s}, opens {s}: {s}", .{ self.item.title(), self.item.linkHost(), self.item.message() }) catch self.item.title()
    else
        std.fmt.bufPrint(&accessible, "{s}: {s}", .{ self.item.title(), self.item.message() }) catch self.item.title();
    target = target.labelled(label);
    if (self.focused(canvas, target)) {
        try canvas.ringAt(bounds, .{ .color = accent, .width = px.px(1.5), .radius = radius });
    }
    self.register(target);

    const icon: Rect = .{ .x = bounds.x + px.px(14), .y = bounds.y + px.px(14), .width = px.px(28), .height = px.px(28) };
    const icon_start = canvas.quads.items().len;
    try canvas.fillRoundedAt(icon, .{ .color = accent, .radius = px.px(9) });
    canvas.quads.fadeFrom(icon_start, 0.14);
    const symbol: Label = .{ .text = switch (self.item.level) {
        .info => "i",
        .success => "\u{2713}",
        .warning => "!",
        .failure => "\u{00d7}",
    }, .color = accent, .face = .sans, .size = .title, .bold = true };
    const symbol_width = try canvas.measure(symbol);
    _ = try canvas.textAt(.{ .x = icon.x + (icon.width - symbol_width) / 2, .y = icon.y, .width = symbol_width, .height = icon.height }, symbol);

    const text_x = bounds.x + px.px(54);
    var title: Label = .{ .text = self.item.title(), .color = palette.text, .face = .sans, .size = .title, .bold = true };
    var title_buffer: [TextFit.max_bytes]u8 = undefined;
    const title_width = bounds.width - px.px(94);
    title.text = try (TextFit{ .canvas = canvas, .width = title_width }).fit(title, &title_buffer);
    _ = try canvas.textAt(.{ .x = text_x, .y = bounds.y + px.px(14), .width = title_width, .height = px.rowHeight(.title) }, title);
    var y = bounds.y + px.px(18) + px.rowHeight(.title);
    for (0..self.body.count) |index| {
        _ = try canvas.textAt(.{ .x = text_x, .y = y, .width = bounds.width - px.px(76), .height = px.rowHeight(.body) }, .{ .text = self.body.line(index), .color = palette.subtext0, .face = .sans, .size = .body });
        y += px.rowHeight(.body);
    }

    if (self.item.clickable()) {
        const action_width = bounds.width - px.px(76);
        var action: Label = .{ .text = switch (self.item.target) {
            .focus_pane => "Open pane \u{2192}",
            .select_tab => "Open tab \u{2192}",
            .select_workspace => "Open workspace \u{2192}",
            .none => "",
        }, .color = accent, .face = .sans, .size = .small, .bold = true, .underline = self.hovered(canvas, target) };
        // A link names its host before the click, so a card cannot pass one
        // page off as another; a host too long to fit keeps its end, where
        // the domain that owns it is.
        var link_buffer: [link_label_bytes]u8 = undefined;
        if (self.item.link_len != 0) {
            action.text = try fitHost(canvas, action, self.item.linkHost(), action_width, &link_buffer);
        }

        _ = try canvas.textAt(.{ .x = text_x, .y = bounds.y + bounds.height - px.px(14) - px.rowHeight(.small), .width = action_width, .height = px.rowHeight(.small) }, action);
    }

    const close: Rect = .{ .x = bounds.x + bounds.width - px.px(34), .y = bounds.y + px.px(8), .width = px.px(26), .height = px.px(26) };
    const dismiss = (Target{ .bounds = close, .action = .{ .intent = .{ .notification_dismiss = self.item.id } }, .namespace = 3, .enabled = target.enabled }).labelled("Dismiss notification");
    if (self.hovered(canvas, dismiss) or self.focused(canvas, dismiss)) {
        try canvas.fillRoundedAt(close, .{ .color = palette.surface1, .radius = px.px(7) });
    }
    if (self.focused(canvas, dismiss)) {
        try canvas.ringAt(close, .{ .color = accent, .width = px.px(1), .radius = px.px(7) });
    }

    const cross: Label = .{ .text = "\u{00d7}", .color = palette.subtext0, .face = .sans, .size = .title };
    const cross_width = try canvas.measure(cross);
    _ = try canvas.textAt(.{ .x = close.x + (close.width - cross_width) / 2, .y = close.y, .width = cross_width, .height = close.height }, cross);
    self.register(dismiss);
    canvas.quads.fadeFrom(first, self.opacity);
    canvas.quads.clipFrom(first, self.clip);
}

// "Open HOST ↗", or "Open …END-OF-HOST ↗" cut from the front until it fits
// `width`. Hosts are ASCII, so bytes are graphemes.
fn fitHost(canvas: *Canvas, style: Label, host: []const u8, width: f32, buffer: *[link_label_bytes]u8) ![]const u8 {
    var probe = style;
    probe.text = std.fmt.bufPrint(buffer, "Open {s} \u{2197}", .{host}) catch return host;
    const full = try canvas.measure(probe);
    if (full <= width) {
        return probe.text;
    }

    var keep: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(host.len)) * width / full));
    while (keep > 0) : (keep -= 1) {
        probe.text = std.fmt.bufPrint(buffer, "Open \u{2026}{s} \u{2197}", .{host[host.len - keep ..]}) catch return host;
        if (try canvas.measure(probe) <= width) {
            return probe.text;
        }
    }

    return std.fmt.bufPrint(buffer, "Open \u{2197}", .{}) catch "";
}

fn register(self: *const Card, value: Target) void {
    const hits = self.hits orelse return;
    var target = value;
    const host = self.clip;
    const bounds = target.bounds;
    const x = @max(bounds.x, host.x);
    const y = @max(bounds.y, host.y);
    target.bounds = .{ .x = x, .y = y, .width = @max(0, @min(bounds.x + bounds.width, host.x + host.width) - x), .height = @max(0, @min(bounds.y + bounds.height, host.y + host.height) - y) };
    hits.hits[hits.count] = target;
    hits.count += 1;
}

fn accentColor(self: *const Card, canvas: *const Canvas) cellgrid.Color {
    return switch (self.item.level) {
        .info => canvas.theme.palette.blue,
        .success => canvas.theme.palette.green,
        .warning => canvas.theme.palette.yellow,
        .failure => canvas.theme.palette.red,
    };
}

fn hovered(_: *const Card, canvas: *const Canvas, target: Target) bool {
    const widgets = canvas.widgets orelse return false;
    const id = widgets.dispatcher.hovered orelse return false;
    const previous = widgets.dispatcher.maps.presented().find(id) orelse return false;
    return previous.namespace == target.namespace and std.meta.eql(previous.action, target.action);
}

fn focused(_: *const Card, canvas: *const Canvas, target: Target) bool {
    const widgets = canvas.widgets orelse return false;
    const previous = widgets.dispatcher.focusedTarget() orelse return false;
    return previous.namespace == target.namespace and std.meta.eql(previous.action, target.action);
}
