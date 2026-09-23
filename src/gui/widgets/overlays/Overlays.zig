const router_module = @import("../../input/router.zig");
const modal_widget = @import("modal_widget.zig");
const data = @import("model");
const client = @import("telar-client");
const HitState = @import("HitState.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const HistoryModal = @import("HistoryModal.zig");
const Notifications = @import("Notifications.zig");
const ModalMotion = @import("ModalMotion.zig");
const OverlayComposition = @import("OverlayComposition.zig");
const Overlays = @This();

maps: GenericPresentedState(HitState) = .{},
notifications: Notifications = .{},
history_motion: ModalMotion = .{},
gesture: ?u8 = null,
/// The native keymap, for the palette's bound-key column.
router: ?*const router_module.Type = null,
/// Host scale, so the palette's logical width becomes cells.
scale: f32 = 1,

/// Selects cards and the active modal without emitting quads. The list borrows
/// the projection and pending hit storage until it finishes drawing.
/// Example: `try overlays.compose(input, &widgets);`
pub fn compose(self: *Overlays, input: OverlayComposition, widgets: anytype) !void {
    const pending = self.maps.begin();
    pending.history_metrics = .fromCanvas(input.canvas);
    const cards = try self.notifications.prepare(input.canvas, input.projection.*);
    for (cards.storage[0..cards.len]) |value| {
        var card = value;
        card.hits = &pending.notifications;
        try widgets.append(.{ .notification = card });
    }

    var modal_input = input;
    modal_input.router = self.router;
    modal_input.scale = self.scale;
    const history_generation = if (input.projection.prompt) |prompt| if (prompt.target() == .history) prompt.generation else null else null;
    modal_input.history_reveal = self.history_motion.sample(history_generation, input.canvas.animation);
    try modal_widget.compose(modal_input, pending, widgets);
}

/// Seal after all widgets have drawn and registered their controls.
/// Example: `overlays.seal();`
pub fn seal(self: *Overlays) void {
    self.maps.seal();
}

/// Publishes only the controls belonging to the host's completed frame token.
/// Example: `overlays.present(delivered);`.
pub fn present(self: *Overlays, delivered: bool) void {
    self.maps.present(delivered);
}

pub fn prepared(self: *const Overlays) *const HitState {
    return self.maps.prepared();
}

pub fn presented(self: *const Overlays) *const HitState {
    return self.maps.presented();
}

/// Consumes modal gestures even outside their rectangle and retains their owner
/// through release if a prompt closes between pointer events. A primary
/// press on a palette row chooses that row.
/// Example: `if (overlays.pointer(mouse)) |interaction| return interaction;`.
pub fn pointer(self: *Overlays, mouse: data.Mouse) ?client.ViewInteractionCommand {
    const button = mouse.button & 3;
    const captured = self.gesture != null;
    if (mouse.kind == .release and self.gesture == button) {
        self.gesture = null;
    }

    const visible = self.presented();
    if (visible.modal != null or captured) {
        if (mouse.kind == .press and self.gesture == null) {
            self.gesture = button;
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
pub fn cancelPointer(self: *Overlays) void {
    self.gesture = null;
}

/// Exposes the native inspector's wrapping to the shared prompt controller.
/// Example: `const limit = overlays.inspectionScrollLimit(projection);`.
pub fn inspectionScrollLimit(self: *const Overlays, projection: client.Projection) ?u32 {
    return HistoryModal.inspectionScrollLimit(projection, self.presented().history_metrics orelse return null);
}
