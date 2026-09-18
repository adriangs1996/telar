const Rect = @import("../render/Rect.zig");
const Canvas = @import("Canvas.zig");
const Layout = @This();

header: Rect,
body: Rect,
composer: Rect,
footer: Rect,
approval: Rect,

/// Keeps the composer and actions inside tiny panes in one content column.
/// Example: `const layout = ThreadLayout.resolve(canvas, bounds, .{ .blocked = blocked });`
pub fn resolve(canvas: *const Canvas, bounds: Rect, options: @import("ThreadLayoutOptions.zig")) Layout {
    const inset = @min(canvas.chrome.px(24), bounds.width / 12);
    const width = @min(canvas.chrome.px(880), @max(0, bounds.width - 2 * inset));
    const x = bounds.x + (bounds.width - width) / 2;
    const header_height = @min(canvas.chrome.px(56), bounds.height / 5);
    const footer_height = @min(canvas.chrome.px(22), bounds.height / 12);
    const preferred_height = (if (options.images) canvas.chrome.px(48) else @as(f32, 0)) + canvas.chrome.px(if (width < canvas.chrome.px(270)) @as(f32, 266) else if (width < canvas.chrome.px(520)) 234 else 206);
    const composer_height = @min(preferred_height, @max(0, bounds.height - header_height - footer_height) * 0.65);
    const approval_height = if (options.blocked) @min(canvas.chrome.px(116), @max(0, bounds.height - header_height - footer_height - composer_height)) else 0;
    const footer_y = bounds.y + bounds.height - footer_height;
    const composer_y = footer_y - composer_height;
    const approval_y = composer_y - approval_height;
    return .{
        .header = .{ .x = x, .y = bounds.y, .width = width, .height = header_height },
        .body = .{ .x = x, .y = bounds.y + header_height, .width = width, .height = @max(0, approval_y - bounds.y - header_height - canvas.chrome.px(12)) },
        .composer = .{ .x = x, .y = composer_y, .width = width, .height = composer_height },
        .footer = .{ .x = x, .y = footer_y, .width = width, .height = footer_height },
        .approval = .{ .x = x, .y = approval_y, .width = width, .height = approval_height },
    };
}
