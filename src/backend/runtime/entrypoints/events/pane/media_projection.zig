//! Synchronization of one pane's graphics state across client attachments.

const std = @import("std");
const attachment_mod = @import("../../../attachment/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const test_support = @import("../../../tests/support.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const Pane = pane_mod.Pane;

pub const Stats = struct {
    staged: u64 = 0,
};

/// Invalidates reset projections first, then freezes at most one transfer per
/// client while the pane's media storage is idle. A failed freeze abandons
/// only that disposable client projection.
///
/// ```zig
/// const stats = synchronize(pane, attachment_stores, media_reset);
/// ```
pub fn synchronize(pane: *Pane, stores: []const *AttachmentStore, media_reset: bool) Stats {
    if (media_reset) {
        for (stores) |store| {
            _ = store.requestGraphicsSnapshot(pane.id);
        }
    }

    var stats: Stats = .{};
    for (stores) |store| {
        const attachment = store.find(pane.id) orelse continue;

        if (attachment.hasFrozenGraphics() or attachment.graphicsCaughtUp()) {
            continue;
        }

        const staged = attachment.stageGraphics(store.availableGraphicsCredit()) catch {
            attachment.abandonGraphics();
            continue;
        };
        if (staged == .staged) {
            stats.staged +|= 1;
        }
    }

    return stats;
}

test "a media reset invalidates every attached client before staging" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var second: AttachmentStore = .{};
    _ = try second.attach(std.testing.allocator, fixture.pane);
    defer second.deinit();
    const stores = [_]*AttachmentStore{ &fixture.attachments, &second };

    const stats = synchronize(fixture.pane, &stores, true);

    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(fixture.attachments.find(fixture.pane.id).?.hasGraphicsWork());
    try std.testing.expect(second.find(fixture.pane.id).?.hasGraphicsWork());
    try std.testing.expect(!fixture.attachments.find(fixture.pane.id).?.hasFrozenGraphics());
    try std.testing.expect(!second.find(fixture.pane.id).?.hasFrozenGraphics());
}

test "one idle-boundary pass freezes at most one transfer per client" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const first = synchronize(fixture.pane, &stores, false);
    const second = synchronize(fixture.pane, &stores, false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 1), first.staged);
    try std.testing.expectEqual(@as(u64, 0), second.staged);
    try std.testing.expect(attachment.hasFrozenGraphics());
}

test "a failed freeze abandons only its client graphics projection" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();
    fixture.failNextAttachmentAllocation();
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const stats = synchronize(fixture.pane, &stores, false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(!attachment.hasFrozenGraphics());
    try std.testing.expect(attachment.graphicsCaughtUp());
}
