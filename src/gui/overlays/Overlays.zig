const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../chrome/Canvas.zig");
const Modal = @import("Modal.zig");
const HitState = @import("HitState.zig");
const GenericPresentedState = @import("../render/GenericPresentedState.zig").Type;
const name_prompt = @import("name_prompt.zig");
const picker = @import("picker.zig");
const history = @import("history.zig");
const suggestion = @import("suggestion.zig");
const Overlays = @This();

maps: GenericPresentedState(HitState) = .{},
gesture: ?u8 = null,

/// Prepares native modal chrome and its hit map from one borrowed projection.
/// Call after panes and permanent chrome, before sealing the frame.
/// Example: `try overlays.paint(canvas, projection);`.
pub fn paint(overlays: *Overlays, canvas: *Canvas, projection: client.Projection) !void {
    const pending = overlays.maps.begin();
    try pending.notifications.paint(canvas, projection);
    const prompt = projection.prompt orelse {
        overlays.maps.seal();
        return;
    };
    const host: core.Rect = .{ .w = projection.host_size.cols, .h = projection.host_size.rows };
    const area = switch (prompt.target()) {
        .history => history.area(projection),
        .goto => Modal.bounds(host, .{ .w = 84, .h = 18 }),
        .suggest => Modal.bounds(host, .{ .w = 84, .h = 9 }),
        else => Modal.bounds(host, .{ .w = 64, .h = 7 }),
    };
    pending.modal = area;
    const modal: Modal = .{ .canvas = canvas, .area = area };
    switch (prompt.target()) {
        .goto => try picker.paint(modal, projection),
        .history => try history.paint(modal, projection),
        .suggest => try suggestion.paint(modal, projection),
        else => try name_prompt.paint(modal, prompt),
    }
    overlays.maps.seal();
}

/// Publishes only the controls belonging to the host's completed frame token.
/// Example: `overlays.present(delivered);`.
pub fn present(overlays: *Overlays, delivered: bool) void {
    overlays.maps.present(delivered);
}

pub fn prepared(overlays: *const Overlays) *const HitState {
    return overlays.maps.prepared();
}

pub fn presented(overlays: *const Overlays) *const HitState {
    return overlays.maps.presented();
}

/// Consumes modal gestures even outside their rectangle and retains their owner
/// through release if a prompt closes between pointer events.
/// Example: `if (overlays.pointer(mouse)) |interaction| return interaction;`.
pub fn pointer(overlays: *Overlays, mouse: client.Mouse) ?client.ViewInteractionCommand {
    const button = mouse.button & 3;
    const captured = overlays.gesture != null;
    if (mouse.kind == .release and overlays.gesture == button) {
        overlays.gesture = null;
    }

    const visible = overlays.presented();
    if (visible.modal != null or captured) {
        if (mouse.kind == .press and overlays.gesture == null) {
            overlays.gesture = button;
        }

        return .{ .consumed = true };
    }

    const intent = visible.notifications.at(mouse) orelse return null;
    if (mouse.kind == .press) {
        overlays.gesture = button;
        return .{ .consumed = true, .intent = if (button == 0) intent else .none };
    }

    return .{ .consumed = true };
}

/// Cancels pointer ownership when the native window loses focus.
/// Example: `overlays.cancelPointer();`.
pub fn cancelPointer(overlays: *Overlays) void {
    overlays.gesture = null;
}

/// Exposes the native inspector's wrapping to the shared prompt controller.
/// Example: `const limit = Overlays.inspectionScrollLimit(projection);`.
pub fn inspectionScrollLimit(projection: client.Projection) ?u32 {
    return history.inspectionScrollLimit(projection);
}
