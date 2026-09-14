//! Where the sidebar's cards go: the pixel rectangle they are clipped to
//! and the card geometry of this frame.
const Rect = @import("../render/Rect.zig");
const CardGeometry = @import("CardGeometry.zig");
const SidebarList = @This();

bounds: Rect,
geometry: CardGeometry,

/// The visible part of a card, as its pointer target: the list clips what
/// it paints, so a card scrolled half out of view is hit only where it shows.
/// Example: `try context.bands.add(.{ .area = list.hitArea(card), .action = action });`
pub fn hitArea(list: SidebarList, card: Rect) Rect {
    const top = @max(card.y, list.bounds.y);
    const bottom = @min(card.y + card.height, list.bounds.y + list.bounds.height);
    const left = @max(card.x, list.bounds.x);
    const right = @min(card.x + card.width, list.bounds.x + list.bounds.width);
    return .{ .x = left, .y = top, .width = @max(0, right - left), .height = @max(0, bottom - top) };
}
