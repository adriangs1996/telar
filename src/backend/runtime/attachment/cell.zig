//! Per-client projection and acknowledgement of one pane's cell state.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const telemetry = @import("../observability/root.zig").telemetry;

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;
pub const Pane = pane_mod.Pane;
pub const RuntimeMetrics = telemetry.RuntimeMetrics;

pub const Preparation = @import("Preparation.zig");

pub const Sync = @import("CellSync.zig");

test "viewport pin allocation failure restores the shared screen and sync state" {
    const PaneFixture = @import("../tests/support.zig").PaneFixture;

    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);

    var held_syncs: [64]Sync = undefined;
    var held_count: usize = 0;
    defer for (held_syncs[0..held_count]) |*sync| sync.deinit(fixture.pane);

    fixture.failNextPaneAllocation();
    var failure_observed = false;
    for (&held_syncs) |*sync| {
        sync.* = try Sync.init(std.testing.allocator, fixture.pane);
        sync.snapshot_pending = false;

        const changed = sync.setViewport(fixture.pane, 0) catch |err| {
            if (err != error.OutOfMemory) {
                sync.deinit(fixture.pane);
                return err;
            }

            const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
            try std.testing.expect(sync.viewport_pin == null);
            try std.testing.expect(!sync.snapshot_pending);
            try std.testing.expect(scrollbar.offset + scrollbar.len >= scrollbar.total);
            sync.deinit(fixture.pane);
            failure_observed = true;
            break;
        };

        try std.testing.expect(changed);
        held_count += 1;
    }

    const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
    try std.testing.expect(failure_observed);
    try std.testing.expect(fixture.pane_allocator.has_induced_failure);
    try std.testing.expect(scrollbar.offset + scrollbar.len >= scrollbar.total);
}
