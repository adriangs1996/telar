//! Per-client projection and acknowledgement of one pane's cell state.

const PaneFixtureType = @import("../tests/PaneFixture.zig");
const std = @import("std");
const CellSync = @import("CellSync.zig");

test "viewport pin allocation failure restores the shared screen and sync state" {
    const PaneFixture = PaneFixtureType;

    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);

    var held_syncs: [64]CellSync = undefined;
    var held_count: usize = 0;
    defer for (held_syncs[0..held_count]) |*sync| sync.deinit(fixture.pane);

    fixture.failNextPaneAllocation();
    var failure_observed = false;
    for (&held_syncs) |*sync| {
        sync.* = try CellSync.init(std.testing.allocator, fixture.pane);
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
