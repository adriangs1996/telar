const CursorAppearance = @import("CursorAppearance.zig");
pub const Shape = CursorAppearance.Shape;

visible: bool = false,
x: u16 = 0,
y: u16 = 0,
appearance: CursorAppearance.CursorAppearance = .{},
