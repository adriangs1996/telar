//! A child mouse gesture retains stable identity, never a borrowed pane.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Capture = @This();

pane_id: core.PaneId,
generation: u64,
location: core.TabLocation,

/// A left press that starts selection belongs to copy mode, not this lease.
/// Example: `const capture = Capture.begin(app, mouse);`
pub fn begin(app: *client.AttachedClient, event: client.Mouse) ?Capture {
    const model = app.model.activeTabModel() orelse return null;
    const plan = model.planPaneMouse(event, app.geometry().area) orelse return null;
    if (!plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10) {
        return null;
    }

    const pane = model.find(plan.pane_id) orelse return null;
    return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .location = app.model.activeTabLocation() orelse return null };
}

/// Reprojects drag/up after focus changes; detachment makes it stale instead
/// of assigning a new owner. Example: `try capture.deliver(app, mouse);`
pub fn deliver(capture: Capture, app: *client.AttachedClient, event: client.Mouse) !void {
    const location = app.model.activeTabLocation() orelse return;
    if (!std.meta.eql(location, capture.location)) {
        return;
    }

    const model = app.model.activeTabModel() orelse return;
    const pane = model.find(capture.pane_id) orelse return;
    if (pane.attachment_generation != capture.generation) {
        return;
    }

    const view = model.viewForPane(pane.id, app.geometry().area) orelse return;
    if (view.content.isEmpty()) {
        return;
    }

    const size = app.model.hostSize();
    var projected = event;
    projected.x = std.math.clamp(event.x, view.content.x, view.content.x + view.content.w - 1);
    projected.y = std.math.clamp(event.y, view.content.y, view.content.y + view.content.h - 1);
    projected.raw_x = std.math.clamp(event.raw_x, @as(u32, view.content.x) * size.cell_width_px, @as(u32, view.content.x + view.content.w) * size.cell_width_px - 1);
    projected.raw_y = std.math.clamp(event.raw_y, @as(u32, view.content.y) * size.cell_height_px, @as(u32, view.content.y + view.content.h) * size.cell_height_px - 1);
    const plan = client.MultiplexerModel.paneMousePlan(pane, view.content);
    if (plan.pane_id != capture.pane_id or !plan.protocol.sgr or plan.protocol.tracking == .none or plan.protocol.tracking == .x10 or (event.kind == .drag and plan.protocol.tracking == .normal)) {
        return;
    }

    try client.controllers.pane_mouse_inputs.reportRetained(app, .{
        .plan = plan,
        .command = .{ .event = projected, .exterior_pixels = true, .cell_width_px = size.cell_width_px, .cell_height_px = size.cell_height_px },
    });
}
