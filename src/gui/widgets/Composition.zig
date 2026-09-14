//! Owns the frame-local context borrowed by its widget list. Keep this value
//! and its projection at stable addresses until the list finishes drawing.
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Context = @import("../chrome/Context.zig");
const frame_widget = @import("frame_widget.zig");
const copy_selection = @import("../render/copy_selection.zig");
const Composition = @This();

chrome: *@import("../chrome/Chrome.zig"),
overlays: *@import("../overlays/Overlays.zig"),
canvas: *Canvas,
link: ?*const @import("../input/LinkHit.zig") = null,
context: Context = undefined,
commit: client.PresentationCommit = .{},

/// Selects the frame's widgets in painter order without emitting quads. The
/// returned list borrows this composition and the caller's projection until draw.
/// Example: `const widgets = try composition.render(&projection); try widgets.draw(canvas);`
pub fn render(composition: *Composition, projection: *const client.Projection) !frame_widget.List {
    var widgets: frame_widget.List = .{};
    composition.commit = .{};
    if (projection.model) |model| {
        composition.commit.location = model.location;
        var layout: client.LayoutSnapshot = .{};
        model.layout.snapshot(projection.geometry.area, &layout);
        for (layout.views()) |view| {
            if (view.surface != .terminal) {
                continue;
            }

            const pane = model.findConst(view.pane_id) orelse continue;
            try widgets.append(.{ .terminal_pane = .{ .paint = .{ .pane = pane, .view = view, .copy = copy_selection.forPane(projection.copy, pane.id), .hide_cursor = projection.prompt != null } } });
            composition.commit.append(pane);
        }

        for (layout.views()) |view| {
            if (view.surface == .terminal) {
                continue;
            }

            if (projection.threadView(view.pane_id)) |thread| {
                try widgets.append(.{ .thread = .{ .area = view.content, .thread = thread } });
                if (model.findConst(view.pane_id)) |pane| {
                    composition.commit.append(pane);
                }
            }
        }

        if (composition.link) |hit| {
            if (model.findConst(hit.pane_id)) |pane| {
                if (pane.attachment_generation == hit.generation) {
                    try widgets.append(.{ .link = .{ .hit = hit, .pane = pane } });
                }
            }
        }
    }

    composition.context = try composition.chrome.begin(composition.canvas, projection);
    try composition.chrome.compose(&composition.context, &widgets);
    try widgets.append(.{ .chrome_focus = .{ .chrome = composition.chrome, .projection = projection } });
    try composition.overlays.compose(.{ .canvas = composition.canvas, .projection = projection }, &widgets);
    return widgets;
}
