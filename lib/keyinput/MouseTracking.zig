/// The mouse events a child application asked to receive: none, presses
/// only (X10), presses, releases and wheel (normal), plus drags (button),
/// or every motion (any).
pub const MouseTracking = enum(u8) {
    none = 0,
    x10 = 1,
    normal = 2,
    button = 3,
    any = 4,
};
