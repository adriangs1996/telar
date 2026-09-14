//! Physical pixels from the content top-left. The button identifies the
//! gesture owner; modifier bits are Shift=1, Alt=2, Control=4 and Super=8.
const PointerEvent = @This();

kind: Kind,
button: Button = .left,
mods: u4 = 0,
x: f64 = 0,
y: f64 = 0,

pub const Kind = enum { press, release, drag, scroll_up, scroll_down, move, leave };
pub const Button = enum(u2) { left, middle, right };

/// Drag and release belong to the owner chosen at press, across layout changes.
/// Example: `if (event.retained()) routeToCapture();`
pub fn retained(event: PointerEvent) bool {
    return event.kind == .release or event.kind == .drag;
}

/// Hover and leave do not interrupt a pending keyboard prefix.
/// Example: `if (event.interruptsKeys()) router.cancelSequence();`
pub fn interruptsKeys(event: PointerEvent) bool {
    return event.kind != .move and event.kind != .leave;
}
