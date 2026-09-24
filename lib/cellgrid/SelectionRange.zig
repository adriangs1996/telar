const Point = @import("Point.zig");
const select = @import("selection.zig");
const Buffer = @import("Buffer.zig");
const Range = @This();

anchor: Point,
head: Point,
mode: select.Mode = .linear,
granularity: select.Granularity = .character,

/// A bare click before any drag. A word or line selection collapsed onto
/// one cell still selects that cell.
pub fn isEmpty(self: Range) bool {
    return self.anchor.x == self.head.x and self.anchor.y == self.head.y and self.granularity == .character;
}

/// Anchor and head in reading order.
pub fn ordered(self: Range) [2]Point {
    return if (select.pointBefore(self.anchor, self.head) or
        (self.anchor.x == self.head.x and self.anchor.y == self.head.y))
        .{ self.anchor, self.head }
    else
        .{ self.head, self.anchor };
}

/// Whether a cell is inside, which is all the highlighting needs to know.
pub fn contains(self: Range, x: u16, y: u16) bool {
    const from, const to = self.ordered();
    return switch (self.mode) {
        .block => x >= @min(from.x, to.x) and x <= @max(from.x, to.x) and
            y >= from.y and y <= to.y,
        .linear => {
            if (y < from.y or y > to.y) {
                return false;
            }
            if (from.y == to.y) {
                return x >= from.x and x <= to.x;
            }
            if (y == from.y) {
                return x >= from.x;
            }
            if (y == to.y) {
                return x <= to.x;
            }
            return true;
        },
    };
}

/// Grows the range to whole words or whole rows.
///
/// Applied on every drag rather than once at the start, because a
/// double-click-and-drag selects by word all the way along - the behaviour
/// people rely on without noticing it exists.
pub fn expanded(self: Range, b: *const Buffer) Range {
    var from, var to = self.ordered();
    switch (self.granularity) {
        .character => {},
        .word => {
            from.x = select.wordStart(b, from);
            to.x = select.wordEnd(b, to);
        },
        .line => {
            from.x = 0;
            to.x = if (b.w == 0) 0 else b.w - 1;
        },
    }
    // The granularity survives so that a word or line selection collapsed
    // onto a single cell is not mistaken for a bare click by `isEmpty`.
    // Expansion is idempotent, so re-expanding the result is harmless.
    return .{ .anchor = from, .head = to, .mode = self.mode, .granularity = self.granularity };
}
