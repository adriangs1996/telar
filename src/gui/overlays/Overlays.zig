const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../chrome/Canvas.zig");
const Modal = @import("Modal.zig");
const Notifications = @import("Notifications.zig");
const name_prompt = @import("name_prompt.zig");
const picker = @import("picker.zig");
const history = @import("history.zig");
const suggestion = @import("suggestion.zig");
const Overlays = @This();

modal: ?core.Rect = null,
notifications: Notifications = .{},
gesture: bool = false,

/// Prepares native modal chrome and its hit map from one borrowed projection.
/// Call after panes and permanent chrome, before sealing the frame.
/// Example: `try overlays.paint(canvas, projection);`.
pub fn paint(overlays: *Overlays, canvas: *Canvas, projection: client.Projection) !void {
    overlays.modal = null;
    try overlays.notifications.paint(canvas, projection);
    const prompt = projection.prompt orelse return;
    const host: core.Rect = .{ .w = projection.host_size.cols, .h = projection.host_size.rows };
    const area = switch (prompt.target()) {
        .history => history.area(projection),
        .goto => Modal.bounds(host, .{ .w = 84, .h = 18 }),
        .suggest => Modal.bounds(host, .{ .w = 84, .h = 9 }),
        else => Modal.bounds(host, .{ .w = 64, .h = 7 }),
    };
    overlays.modal = area;
    const modal: Modal = .{ .canvas = canvas, .area = area };
    switch (prompt.target()) {
        .goto => try picker.paint(modal, projection),
        .history => try history.paint(modal, projection),
        .suggest => try suggestion.paint(modal, projection),
        else => try name_prompt.paint(modal, prompt),
    }
}

/// Consumes modal gestures even outside their rectangle and retains their owner
/// through release if a prompt closes between pointer events.
/// Example: `if (overlays.pointer(mouse)) |interaction| return interaction;`.
pub fn pointer(overlays: *Overlays, mouse: client.Mouse) ?client.ViewInteractionCommand {
    const captured = overlays.gesture;
    if (mouse.kind == .release) {
        overlays.gesture = false;
    }

    if (overlays.modal != null or captured) {
        if (mouse.kind == .press) {
            overlays.gesture = true;
        }

        return .{ .consumed = true };
    }

    const intent = overlays.notifications.at(mouse) orelse return null;
    if (mouse.kind == .press) {
        overlays.gesture = true;
        return .{ .consumed = true, .intent = if (mouse.button == 0) intent else .none };
    }

    return .{ .consumed = true };
}

/// Exposes the native inspector's wrapping to the shared prompt controller.
/// Example: `const limit = Overlays.inspectionScrollLimit(projection);`.
pub fn inspectionScrollLimit(projection: client.Projection) ?u32 {
    return history.inspectionScrollLimit(projection);
}
