//! A child mouse gesture retains stable identity, never a borrowed pane.
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
pub fn begin(app: *client.AttachedClient, event: client.Mouse) ?Capture {
    const model = app.model.activeTabModel() orelse return null;
    const plan = model.planPaneMouse(event, app.geometry().area) orelse return null;
    if (!plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10) {
        return null;
    }

    const pane = model.find(plan.pane_id) orelse return null;
    const size = app.model.hostSize();
    if (size.cell_width_px == 0 or size.cell_height_px == 0) {
        return null;
    }

    return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .location = app.model.activeTabLocation() orelse return null, .content = plan.content, .cell_width = size.cell_width_px, .cell_height = size.cell_height_px };
}

/// Visible panes update the captured geometry. Hidden panes keep their last
/// rectangle so a tab or fullscreen change cannot strand an acquired press.
/// Detachment still invalidates the lease. Example: `try capture.deliver(app, mouse);`
pub fn deliver(capture: *Capture, app: *client.AttachedClient, event: client.Mouse) !void {
    const tab = app.model.workspace.find(capture.location.tab_id) orelse return;
    if (!std.meta.eql(tab.location, capture.location)) {
        return;
    }

    const model = &tab.model;
    const pane = model.find(capture.pane_id) orelse return;
    if (!pane.attached or pane.attachment_generation != capture.generation) {
        return;
    }

    const size = app.model.hostSize();
    if (std.meta.eql(app.model.activeTabLocation(), @as(?core.TabLocation, capture.location))) {
        if (model.viewForPane(pane.id, app.geometry().area)) |view| {
            if (!view.content.isEmpty() and size.cell_width_px != 0 and size.cell_height_px != 0) {
                capture.content = view.content;
                capture.cell_width = size.cell_width_px;
                capture.cell_height = size.cell_height_px;
            }
        }
    }

    var content = capture.content;
    content.w = @min(content.w, pane.buffer.w);
    content.h = @min(content.h, pane.buffer.h);
    if (content.isEmpty()) {
        return;
    }

    var projected = event;
    projected.x = std.math.clamp(event.x, content.x, content.x + content.w - 1);
    projected.y = std.math.clamp(event.y, content.y, content.y + content.h - 1);
    projected.raw_x = std.math.clamp(event.raw_x, @as(u32, content.x) * capture.cell_width, @as(u32, content.x + content.w) * capture.cell_width - 1);
    projected.raw_y = std.math.clamp(event.raw_y, @as(u32, content.y) * capture.cell_height, @as(u32, content.y + content.h) * capture.cell_height - 1);
    const plan = client.MultiplexerModel.paneMousePlan(pane, content);
    if (plan.pane_id != capture.pane_id or !plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10 or (event.kind == .drag and plan.protocol.tracking == .normal)) {
        return;
    }

    try client.controllers.pane_mouse_inputs.reportRetained(app, .{
        .plan = plan,
        .command = .{ .event = projected, .exterior_pixels = true, .cell_width_px = capture.cell_width, .cell_height_px = capture.cell_height },
    });
}
