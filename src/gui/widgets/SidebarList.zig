//! The viewport shared by sidebar entries and their clipped pointer targets.
const Rect = @import("../render/Rect.zig");
const SidebarList = @This();

bounds: Rect,

/// The visible part of a card, as its pointer target: the list clips what
/// it paints, so a card scrolled half out of view is hit only where it shows.
/// Example: `try context.bands.add(.{ .area = list.hitArea(card), .action = action });`
pub fn hitArea(self: SidebarList, card: Rect) Rect {
    const top = @max(card.y, self.bounds.y);
    const bottom = @min(card.y + card.height, self.bounds.y + self.bounds.height);
    const left = @max(card.x, self.bounds.x);
    const right = @min(card.x + card.width, self.bounds.x + self.bounds.width);
    return .{ .x = left, .y = top, .width = @max(0, right - left), .height = @max(0, bottom - top) };
}
