//! Disposable reader selection; source ownership remains in the pinned window.
const core = @import("telar-core");
const Selection = @This();
const Position = @import("ThreadTextPosition.zig");
const MessageLinkControl = @import("MessageLinkControl.zig");
const Owner = @import("ThreadSelectionOwner.zig");
const ThreadSelectionClipboard = @import("ThreadSelectionClipboard.zig");
owner: ?Owner = null,
release: ?Owner = null,
anchor: ?Position = null,
head: ?Position = null,
keyboard: bool = false,
dragging: bool = false,
pending_link: ?MessageLinkControl = null,
frozen: bool = false,
blocked_edge: bool = false,
pointer: [2]f64 = .{ 0, 0 },
outside: i8 = 0,
next_scroll_ns: u64 = 0,
selecting: bool = false,
pending_vertical: i8 = 0,
preferred_x: ?f64 = null,
clipboard: ?ThreadSelectionClipboard = null,
problem: ?enum { copy_limit, copy_failed, geometry_limit } = null,

/// Example: `if (selection.selected()) copyRange();`
pub fn selected(self: *const Selection) bool {
    const a = self.anchor orelse return false;
    const b = self.head orelse return false;
    return !a.eql(b);
}

/// Example: `if (selection.retains(pane_id)) keepPages();`
pub fn retains(self: *const Selection, pane_id: core.PaneId) bool {
    const owner = self.owner orelse return false;
    return owner.pane_id == pane_id and (self.dragging or self.keyboard or self.selected());
}

/// Clears input state immediately and defers page release to frame preparation.
/// Example: `selection.clear();`
pub fn clear(self: *Selection) void {
    const pending = self.release orelse self.owner;
    self.* = .{ .release = pending };
}

/// Example: `const ordered = selection.range() orelse return;`
pub fn range(self: *const Selection) ?[2]Position {
    const a = self.anchor orelse return null;
    const b = self.head orelse return null;
    return if (b.before(a)) .{ b, a } else .{ a, b };
}

/// Starts another gesture without releasing an already pinned source window.
/// Example: `selection.restart(owner);`
pub fn restart(self: *Selection, owner: Owner) void {
    const retained = if (self.owner) |previous| previous.pane_id == owner.pane_id and previous.attachment_generation == owner.attachment_generation and self.frozen else false;
    const release = if (retained) self.release else self.release orelse self.owner;
    self.* = .{ .owner = owner, .release = release, .frozen = retained };
}
