//! Owns the frame-local context borrowed by its widget list. Keep this value
//! and its projection at stable addresses until the list finishes drawing.
const data = @import("model");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const frame_widget = @import("frame_widget.zig");
const copy_selection = @import("../render/copy_selection.zig");
const Composition = @This();

chrome: *@import("Chrome.zig"),
overlays: *@import("overlays/Overlays.zig"),
canvas: *Canvas,
link: ?*const @import("../input/LinkHit.zig") = null,
context: Context = undefined,
commit: data.PresentationCommit = .{},

/// Selects the frame's widgets in painter order without emitting quads. The
/// returned list borrows this composition and the caller's projection until draw.
/// Example: `const widgets = try composition.render(&projection); try widgets.draw(canvas);`
pub fn render(self: *Composition, projection: *const client.Projection) !frame_widget.List {
    var widgets: frame_widget.List = .{};
    self.commit = .{};
    if (projection.tab) |tab| {
        const model = projection.model;
        const tab_id = model.tabs.location[tab].tab_id;
        self.commit.location = if (model.panes.countIn(tab_id) == 0) null else model.tabs.location[tab];
        const layout = projection.layout.?;
        for (layout.views()) |view| {
            if (view.surface != .terminal) {
                continue;
            }

            const pane = model.panes.findInConst(tab_id, view.pane_id) orelse continue;
            try widgets.append(.{ .terminal_pane = .{ .paint = .{ .pane = pane, .view = view, .copy = copy_selection.forPane(projection.copy, pane.id), .hide_cursor = projection.prompt != null } } });
            self.commit.append(pane);
        }

        for (layout.views()) |view| {
            if (view.surface == .terminal) {
                continue;
            }

            if (projection.threadView(view.pane_id)) |thread| {
                try widgets.append(.{ .thread = .{ .area = view.content, .thread = thread } });
                if (model.panes.findInConst(tab_id, view.pane_id)) |pane| {
                    self.commit.append(pane);
                }
            }
        }

        if (self.link) |hit| {
            if (model.panes.findInConst(tab_id, hit.pane_id)) |pane| {
                if (pane.attachment_generation == hit.generation) {
                    try widgets.append(.{ .link = .{ .hit = hit, .pane = pane } });
                }
            }
        }
    }

    self.context = try self.chrome.begin(self.canvas, projection);
    try self.chrome.compose(&self.context, &widgets);
    try widgets.append(.{ .chrome_focus = .{ .chrome = self.chrome, .projection = projection } });
    try self.overlays.compose(.{ .canvas = self.canvas, .projection = projection }, &widgets);
    return widgets;
}
