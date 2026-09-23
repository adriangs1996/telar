//! One disclosure's reading position, resolved against current geometry and
//! committed only after that frame reaches the host.
const core = @import("telar-core");
const Request = @import("ThreadScrollRequest.zig");
const Resolution = @import("ThreadScrollResolution.zig");
const Geometry = @import("ThreadScrollGeometry.zig");
const Anchor = @This();

sequence: u64 = 0,
pending: ?Request = null,
prepared: ?Resolution = null,

/// Captures a delivered header without retaining its snapshot.
/// Example: `anchor.capture(.{ .control = control, .baseline = scroll, .offset = y });`
pub fn capture(self: *Anchor, request: Request) void {
    self.sequence +%= 1;
    self.pending = request;
    self.pending.?.sequence = self.sequence;
}

/// Explicit navigation supersedes an outstanding disclosure adjustment.
/// Example: `anchor.cancel(pane_id);`
pub fn cancel(self: *Anchor, pane_id: core.PaneId) void {
    if (self.pending) |request| {
        if (request.control.pane_id == pane_id) {
            self.pending = null;
        }
    }
}

/// Measures the requested item with the latest width, text and expansion state.
/// Example: `const scroll = anchor.resolve(geometry) orelse current_scroll;`
pub fn resolve(self: *Anchor, geometry: Geometry) ?f64 {
    const request = self.pending orelse return null;
    if (!request.control.sameItem(geometry.control) or request.baseline != geometry.baseline) {
        return null;
    }

    const desired = (@as(f64, geometry.maximum) - geometry.offset + request.offset) / geometry.step;
    const scroll = @max(0, @min(geometry.limit, desired));
    self.prepared = .{ .request = request, .scroll = scroll };
    self.prepared.?.request.control = geometry.control;
    return scroll;
}

/// A newer click or manual scroll cannot be overwritten by an older delivery.
/// Example: `if (anchor.current(resolution)) commitScroll(resolution.scroll);`
pub fn current(self: *const Anchor, resolution: Resolution) bool {
    const request = self.pending orelse return false;
    return request.sequence == resolution.request.sequence and request.control.sameItem(resolution.request.control);
}
