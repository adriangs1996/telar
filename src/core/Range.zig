const Range = @This();
const source_namespace = @import("select.zig");
const ui = @import("ui/root.zig");
anchor: source_namespace.Point,
head: source_namespace.Point,
mode: source_namespace.Mode = .linear,
granularity: source_namespace.Granularity = .character,

/// A bare click before any drag. A word or line selection collapsed onto
/// one cell still selects that cell.
pub fn isEmpty(r: Range) bool {
    return r.anchor.x == r.head.x and r.anchor.y == r.head.y and r.granularity == .character;
}

/// Anchor and head in reading order.
pub fn ordered(r: Range) [2]source_namespace.Point {
    return if (source_namespace.pointBefore(r.anchor, r.head) or
        (r.anchor.x == r.head.x and r.anchor.y == r.head.y))
        .{ r.anchor, r.head }
    else
        .{ r.head, r.anchor };
}

/// Whether a cell is inside, which is all the highlighting needs to know.
pub fn contains(r: Range, x: u16, y: u16) bool {
    const from, const to = r.ordered();
    return switch (r.mode) {
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
pub fn expanded(r: Range, b: *const ui.Buffer) Range {
    var from, var to = r.ordered();
    switch (r.granularity) {
        .character => {},
        .word => {
            from.x = source_namespace.wordStart(b, from);
            to.x = source_namespace.wordEnd(b, to);
        },
        .line => {
            from.x = 0;
            to.x = if (b.w == 0) 0 else b.w - 1;
        },
    }
    // The granularity survives so that a word or line selection collapsed
    // onto a single cell is not mistaken for a bare click by `isEmpty`.
    // Expansion is idempotent, so re-expanding the result is harmless.
    return .{ .anchor = from, .head = to, .mode = r.mode, .granularity = r.granularity };
}
