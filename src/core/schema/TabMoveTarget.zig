const id = @import("id.zig");
const types = @import("types.zig");
const TabMoveTarget = @This();

direction: types.TabMoveDirection,
/// When present, insert before/after this tab; otherwise move one position.
relative_to: ?id.TabId = null,

/// Resolves the final position after removing the source from its old slot.
/// Example: `const position = destination.positionRelativeTo(source_index, anchor_index);`
pub fn positionRelativeTo(target: TabMoveTarget, source: usize, anchor: usize) usize {
    if (source == anchor) {
        return source;
    }

    const insertion = anchor + @as(usize, if (target.direction == .next) 1 else 0);
    return insertion - @as(usize, if (source < insertion) 1 else 0);
}
