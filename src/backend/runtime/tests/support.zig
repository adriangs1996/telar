//! Runtime fixtures shared only by backend unit and vertical tests.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const pty = @import("../../pty/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

pub const schema = core.schema;

/// Executes a media actor synchronously in a fixture, preserving borrow order.
/// Example: `processMediaTurn(pane);`.
pub fn processMediaTurn(pane: *pane_mod.Pane) void {
    const borrow = pane.beginMediaProcessing() orelse return;
    var stats: @import("../../media/root.zig").Stats = .{};
    pane.processMedia(borrow.current_size, &stats);
    pane.completeMediaProcessing();
}

pub const PaneFixture = @import("PaneFixture.zig");
