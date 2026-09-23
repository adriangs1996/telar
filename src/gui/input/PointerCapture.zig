//! A child mouse gesture retains stable identity, never a borrowed pane.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Capture = @This();

pane_id: core.PaneId,
generation: u64,
location: core.TabLocation,
content: core.Rect,
cell_width: u16,
cell_height: u16,

/// A left press that starts selection belongs to copy mode, not this lease.
/// Example: `const capture = Capture.begin(app, mouse);`
pub fn begin(app: *client.Client, event: data.Mouse) ?Capture {
    const tab = app.model.tabs.activeSlot() orelse return null;
    const plan = data.tab_layout.planPaneMouse(&app.model, tab, event, app.geometry().area) orelse return null;
    if (!plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10) {
        return null;
    }

    const pane = app.model.panes.findIn(app.model.tabs.location[tab].tab_id, plan.pane_id) orelse return null;
    const size = app.model.host.host_size;
    if (size.cell_width_px == 0 or size.cell_height_px == 0) {
        return null;
    }

    return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .location = app.model.activeTabLocation() orelse return null, .content = plan.content, .cell_width = size.cell_width_px, .cell_height = size.cell_height_px };
}

/// Visible panes update the captured geometry. Hidden panes keep their last
/// rectangle so a tab or fullscreen change cannot strand an acquired press.
/// Detachment still invalidates the lease. Example: `try capture.deliver(app, mouse);`
pub fn deliver(self: *Capture, app: *client.Client, event: data.Mouse) !void {
    const tab = app.model.tabs.find(self.location.tab_id) orelse return;
    if (!std.meta.eql(app.model.tabs.location[tab], self.location)) {
        return;
    }

    const pane = app.model.panes.findIn(self.location.tab_id, self.pane_id) orelse return;
    if (!pane.attached or pane.attachment_generation != self.generation) {
        return;
    }

    const size = app.model.host.host_size;
    if (std.meta.eql(app.model.activeTabLocation(), @as(?core.TabLocation, self.location))) {
        if (data.tab_layout.view(&app.model, tab, pane.id, app.geometry().area)) |view| {
            if (!view.content.isEmpty() and size.cell_width_px != 0 and size.cell_height_px != 0) {
                self.content = view.content;
                self.cell_width = size.cell_width_px;
                self.cell_height = size.cell_height_px;
            }
        }
    }

    var content = self.content;
    content.w = @min(content.w, pane.buffer.w);
    content.h = @min(content.h, pane.buffer.h);
    if (content.isEmpty()) {
        return;
    }

    var projected = event;
    projected.x = std.math.clamp(event.x, content.x, content.x + content.w - 1);
    projected.y = std.math.clamp(event.y, content.y, content.y + content.h - 1);
    projected.raw_x = std.math.clamp(event.raw_x, @as(u32, content.x) * self.cell_width, @as(u32, content.x + content.w) * self.cell_width - 1);
    projected.raw_y = std.math.clamp(event.raw_y, @as(u32, content.y) * self.cell_height, @as(u32, content.y + content.h) * self.cell_height - 1);
    const plan = data.tab_layout.paneMousePlan(pane, content);
    if (plan.pane_id != self.pane_id or !plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10 or (event.kind == .drag and plan.protocol.tracking == .normal)) {
        return;
    }

    try client.pane_mouse_input.reportRetainedPaneMouse(app, .{
        .plan = plan,
        .command = .{ .event = projected, .exterior_pixels = true, .cell_width_px = self.cell_width, .cell_height_px = self.cell_height },
    });
}
