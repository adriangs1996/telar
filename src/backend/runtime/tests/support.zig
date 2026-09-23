//! Runtime fixtures shared only by backend unit and vertical tests.

const Pane = @import("../../pane/Pane.zig");
const Stats = @import("../../media/Stats.zig");

/// Executes a media actor synchronously in a fixture, preserving borrow order.
/// Example: `processMediaTurn(pane);`.
pub fn processMediaTurn(pane: *Pane) void {
    const borrow = pane.beginMediaProcessing() orelse return;
    var stats: Stats = .{};
    pane.processMedia(borrow.current_size, &stats);
    pane.completeMediaProcessing();
}

pub const PaneFixture = @import("PaneFixture.zig");
