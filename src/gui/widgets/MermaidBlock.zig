//! A retained diagram image with the same measured geometry at every scale.
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Ready = @import("../diagrams/Ready.zig");
const View = @import("../diagrams/view.zig").View;
const Mermaid = @This();

bounds: Rect,
request: @import("../diagrams/Request.zig"),

/// Consults frame-stable results without admitting work from measurement.
/// Example: `const result = mermaid.lookup(canvas);`
pub fn lookup(widget: Mermaid, canvas: *Canvas) ?View {
    const store = canvas.diagrams orelse return .{ .failed = .unavailable };
    return store.lookup(widget.request);
}

/// Copies a visible source into the bounded queue; the host starts work later.
/// Example: `const result = mermaid.enqueue(canvas);`
pub fn enqueue(widget: Mermaid, canvas: *Canvas) View {
    const store = canvas.diagrams orelse return .{ .failed = .unavailable };
    return store.request(widget.request);
}

/// Keeps the full natural aspect ratio, reducing width only when necessary.
/// Example: `const height = mermaid.measure(canvas, image);`
pub fn measure(widget: Mermaid, canvas: *const Canvas, ready: Ready) f32 {
    return widget.imageBounds(canvas, ready).height + canvas.chrome.px(52);
}

/// Paints a retained image slot; source parsing and decoding belong to workers.
/// Example: `try mermaid.draw(canvas, image);`
pub fn draw(widget: Mermaid, canvas: *Canvas, ready: Ready) !void {
    if (canvas.diagrams) |store| {
        store.pin(widget.request);
    }

    const area = widget.imageBounds(canvas, ready);
    const card: Rect = .{ .x = widget.bounds.x, .y = widget.bounds.y + canvas.chrome.px(4), .width = widget.bounds.width, .height = widget.measure(canvas, ready) - canvas.chrome.px(10) };
    try canvas.fillRoundedAt(card, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(8) });
    try canvas.ringAt(card, .{ .color = canvas.theme.palette.overlay0, .width = 1, .radius = canvas.chrome.px(8), .alpha = 0.4 });
    const inset = @min(canvas.chrome.px(14), widget.bounds.width / 8);
    _ = try canvas.textAt(.{ .x = card.x + inset, .y = card.y, .width = @max(0, card.width - 2 * inset), .height = canvas.chrome.px(30) }, .{ .text = "Diagram", .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
    try canvas.diagramAt(area, ready.slot);
}

/// Gives the code fallback a concise reason without replacing source bytes.
/// Example: `block.language = MermaidBlock.label(result);`
pub fn label(view: ?View) []const u8 {
    return switch (view orelse .pending) {
        .pending => "Mermaid · Rendering diagram",
        .ready => "Mermaid",
        .failed => |failure| switch (failure) {
            .invalid => "Mermaid · Invalid diagram",
            .unsupported => "Mermaid · Unsupported diagram",
            .limit => "Mermaid · Diagram limit reached",
            .unavailable => "Mermaid · Renderer unavailable",
            .timeout => "Mermaid · Rendering timed out",
        },
    };
}

fn imageBounds(widget: Mermaid, canvas: *const Canvas, ready: Ready) Rect {
    const inset = @min(canvas.chrome.px(14), widget.bounds.width / 8);
    const natural_width = @max(1, canvas.chrome.px(ready.logical_width));
    const natural_height = @max(1, canvas.chrome.px(ready.logical_height));
    const width = @min(natural_width, @max(0, widget.bounds.width - 2 * inset));
    return .{ .x = widget.bounds.x + (widget.bounds.width - width) / 2, .y = widget.bounds.y + canvas.chrome.px(40), .width = width, .height = natural_height * (width / natural_width) };
}
