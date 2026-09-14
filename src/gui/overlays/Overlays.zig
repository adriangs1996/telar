const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const HitState = @import("HitState.zig");
const GenericPresentedState = @import("../render/GenericPresentedState.zig").Type;
const HistoryModal = @import("HistoryModal.zig");
const Overlays = @This();

maps: GenericPresentedState(HitState) = .{},
notifications: @import("Notifications.zig") = .{},
gesture: ?u8 = null,
/// The native keymap, for the palette's bound-key column.
router: ?*const @import("../input/router.zig").Type = null,
/// Host scale, so the palette's logical width becomes cells.
scale: f32 = 1,

/// Prepares native modal chrome and its hit map from one borrowed projection.
/// Call after panes and permanent chrome, before sealing the frame.
/// Example: `try overlays.paint(canvas, projection);`.
pub fn paint(overlays: *Overlays, canvas: *Canvas, projection: client.Projection) !void {
    var widgets: @import("../widgets/frame_widget.zig").List = .{};
    try overlays.compose(.{ .canvas = canvas, .projection = &projection }, &widgets);
    try widgets.draw(canvas);
    overlays.seal();
}

/// Selects cards and the active modal without emitting quads. The list borrows
/// the projection and pending hit storage until it finishes drawing.
/// Example: `try overlays.compose(input, &widgets);`
pub fn compose(overlays: *Overlays, input: @import("OverlayComposition.zig"), widgets: anytype) !void {
    const pending = overlays.maps.begin();
    const cards = try overlays.notifications.prepare(input.canvas, input.projection.*);
    for (cards.storage[0..cards.len]) |value| {
        var card = value;
        card.hits = &pending.notifications;
        try widgets.append(.{ .notification = card });
    }

    var modal_input = input;
    modal_input.router = overlays.router;
    modal_input.scale = overlays.scale;
    try @import("modal_widget.zig").compose(modal_input, pending, widgets);
}

/// Seal after all widgets have drawn and registered their controls.
/// Example: `overlays.seal();`
pub fn seal(overlays: *Overlays) void {
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
/// through release if a prompt closes between pointer events. A primary
/// press on a palette row chooses that row.
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
            if (button == 0 and visible.modal != null) {
                if (visible.palette.at(mouse)) |index| {
                    return .{ .consumed = true, .intent = .{ .prompt_row = index } };
                }
            }
        }

        return .{ .consumed = true };
    }

    return null;
}

/// Cancels pointer ownership when the native window loses focus.
/// Example: `overlays.cancelPointer();`.
pub fn cancelPointer(overlays: *Overlays) void {
    overlays.gesture = null;
}

/// Exposes the native inspector's wrapping to the shared prompt controller.
/// Example: `const limit = Overlays.inspectionScrollLimit(projection);`.
pub fn inspectionScrollLimit(projection: client.Projection) ?u32 {
    return HistoryModal.inspectionScrollLimit(projection);
}
