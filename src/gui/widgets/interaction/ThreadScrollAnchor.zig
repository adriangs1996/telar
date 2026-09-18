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
pub fn capture(anchor: *Anchor, request: Request) void {
    anchor.sequence +%= 1;
    anchor.pending = request;
    anchor.pending.?.sequence = anchor.sequence;
}

/// Explicit navigation supersedes an outstanding disclosure adjustment.
/// Example: `anchor.cancel(pane_id);`
pub fn cancel(anchor: *Anchor, pane_id: core.PaneId) void {
    if (anchor.pending) |request| {
        if (request.control.pane_id == pane_id) {
            anchor.pending = null;
        }
    }
}

/// Measures the requested item with the latest width, text and expansion state.
/// Example: `const scroll = anchor.resolve(geometry) orelse current_scroll;`
pub fn resolve(anchor: *Anchor, geometry: Geometry) ?f64 {
    const request = anchor.pending orelse return null;
    if (!request.control.sameItem(geometry.control) or request.baseline != geometry.baseline) {
        return null;
    }

    const desired = (@as(f64, geometry.maximum) - geometry.offset + request.offset) / geometry.step;
    const scroll = @max(0, @min(geometry.limit, desired));
    anchor.prepared = .{ .request = request, .scroll = scroll };
    anchor.prepared.?.request.control = geometry.control;
    return scroll;
}

/// A newer click or manual scroll cannot be overwritten by an older delivery.
/// Example: `if (anchor.current(resolution)) commitScroll(resolution.scroll);`
pub fn current(anchor: *const Anchor, resolution: Resolution) bool {
    const request = anchor.pending orelse return false;
    return request.sequence == resolution.request.sequence and request.control.sameItem(resolution.request.control);
}
