//! Disposable reader selection; source ownership remains in the pinned window.
const Selection = @This();
const Position = @import("ThreadTextPosition.zig");
const Owner = @import("ThreadSelectionOwner.zig");
owner: ?Owner = null,
release: ?Owner = null,
anchor: ?Position = null,
head: ?Position = null,
keyboard: bool = false,
dragging: bool = false,
frozen: bool = false,
blocked_edge: bool = false,
pointer: [2]f64 = .{ 0, 0 },
outside: i8 = 0,
next_scroll_ns: u64 = 0,
selecting: bool = false,
pending_vertical: i8 = 0,
preferred_x: ?f64 = null,
clipboard: ?@import("ThreadSelectionClipboard.zig") = null,
problem: ?enum { copy_limit, copy_failed, geometry_limit } = null,

/// Example: `if (selection.selected()) copyRange();`
pub fn selected(selection: *const Selection) bool {
    const a = selection.anchor orelse return false;
    const b = selection.head orelse return false;
    return !a.eql(b);
}

/// Example: `if (selection.retains(pane_id)) keepPages();`
pub fn retains(selection: *const Selection, pane_id: @import("telar-core").PaneId) bool {
    const owner = selection.owner orelse return false;
    return owner.pane_id == pane_id and (selection.dragging or selection.keyboard or selection.selected());
}

/// Clears input state immediately and defers page release to frame preparation.
/// Example: `selection.clear();`
pub fn clear(selection: *Selection) void {
    const pending = selection.release orelse selection.owner;
    selection.* = .{ .release = pending };
}

/// Example: `const ordered = selection.range() orelse return;`
pub fn range(selection: *const Selection) ?[2]Position {
    const a = selection.anchor orelse return null;
    const b = selection.head orelse return null;
    return if (b.before(a)) .{ b, a } else .{ a, b };
}

/// Starts another gesture without releasing an already pinned source window.
/// Example: `selection.restart(owner);`
pub fn restart(selection: *Selection, owner: Owner) void {
    const retained = if (selection.owner) |previous| previous.pane_id == owner.pane_id and previous.attachment_generation == owner.attachment_generation and selection.frozen else false;
    const release = if (retained) selection.release else selection.release orelse selection.owner;
    selection.* = .{ .owner = owner, .release = release, .frozen = retained };
}
