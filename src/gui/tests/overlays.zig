const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const Modal = @import("../overlays/Modal.zig");
const Overlays = @import("../overlays/Overlays.zig");
const WrappedLines = @import("../overlays/WrappedLines.zig");
const thread = @import("../overlays/thread.zig");

test "native prompt renders selections and owns its gesture until release" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(1), .label = "e\u{301}界 terminal" } });
    _ = fixture.model.name_prompt.apply(.{ .home = true });
    const original = fixture.model.name_prompt.currentConst().?.*;
    try fixture.paint();
    try std.testing.expect(fixture.renderer.quads.items().len > 10);
    try std.testing.expectEqualDeep(original, fixture.model.name_prompt.currentConst().?.*);

    const modal = fixture.overlays.presented().modal.?;
    try std.testing.expect(modal.x > 0 and modal.y > 0);
    const press = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press }).?;
    try std.testing.expect(press.consumed);
    try std.testing.expect(press.intent == .none);
    _ = fixture.model.name_prompt.apply(.cancel);
    try fixture.paint();
    try std.testing.expect(fixture.overlays.presented().modal == null);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .drag }).?.consumed);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .press, .button = 1 }).?.consumed);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .release, .button = 1 }).?.consumed);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .drag }).?.consumed);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .release }).?.consumed);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 1, .y = 1, .kind = .move }) == null);
}

test "native modal closure keeps its presented pointer barrier across failed frames" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const move: client.Mouse = .{ .x = 1, .y = 1, .kind = .move };
    fixture.model.name_prompt.begin(.create_workspace);
    try fixture.prepare();
    try std.testing.expect(fixture.overlays.pointer(move) == null);
    fixture.overlays.present(true);
    const visible = fixture.overlays.presented();
    try std.testing.expect(fixture.overlays.pointer(move).?.consumed);
    const geometry = client.Geometry.capture(fixture.projection());

    _ = fixture.model.name_prompt.apply(.cancel);
    try fixture.prepare();
    const current_geometry = client.Geometry.capture(fixture.projection());
    try std.testing.expect(geometry.matches(&current_geometry));
    try std.testing.expect(fixture.overlays.prepared().modal == null);
    try std.testing.expect(fixture.overlays.pointer(move).?.consumed);
    fixture.overlays.present(false);
    fixture.overlays.present(true);
    try std.testing.expectEqual(visible, fixture.overlays.presented());
    try std.testing.expect(fixture.overlays.pointer(move).?.consumed);

    try fixture.prepare();
    fixture.overlays.present(true);
    try std.testing.expect(fixture.overlays.presented().modal == null);
    try std.testing.expect(fixture.overlays.pointer(move) == null);
}

test "native notification replacement retains the delivered card identity" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const first = fixture.model.publishNotification(0, .{ .title = "First", .message = "Delivered" }).id;
    _ = fixture.model.advanceNotifications(client.transition_duration_ns);
    try fixture.paint();
    const close = fixture.overlays.presented().notifications.hits[1].area;
    _ = fixture.model.dismissNotification(first, client.transition_duration_ns);
    _ = fixture.model.advanceNotifications(client.transition_duration_ns * 2);
    const second = fixture.model.publishNotification(client.transition_duration_ns * 2, .{ .title = "Next", .message = "Prepared" }).id;
    _ = fixture.model.advanceNotifications(client.transition_duration_ns * 3);
    try fixture.prepare();
    try std.testing.expectEqual(close, fixture.overlays.prepared().notifications.hits[1].area);
    const mouse: client.Mouse = .{ .x = close.x, .y = close.y, .kind = .press };
    const release: client.Mouse = .{ .x = 0, .y = 0, .kind = .release };
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = first }, fixture.overlays.pointer(mouse).?.intent);
    _ = fixture.overlays.pointer(release);
    fixture.overlays.present(false);
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = first }, fixture.overlays.pointer(mouse).?.intent);
    _ = fixture.overlays.pointer(release);

    try fixture.prepare();
    fixture.overlays.present(true);
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = second }, fixture.overlays.pointer(mouse).?.intent);
}

test "native modal geometry clips every glyph on tiny hosts and preserves prompt state" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.create_workspace);
    _ = fixture.model.name_prompt.apply(.{ .insert = "A workspace that does not fit" });

    for ([_][2]u16{ .{ 1, 1 }, .{ 3, 2 }, .{ 12, 4 }, .{ 23, 7 }, .{ 160, 60 } }) |size| {
        fixture.size.cols = size[0];
        fixture.size.rows = size[1];
        try fixture.paint();
        var canvas = fixture.canvas();
        const bounds = canvas.rect(fixture.overlays.presented().modal.?);
        for (fixture.renderer.quads.items()) |quad| {
            try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
            try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
            try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
        }
    }

    try std.testing.expectEqualStrings("A workspace that does not fit", fixture.model.name_prompt.currentConst().?.field.text());
}

test "native overlay gestures ignore modifier bits and cancel on focus loss" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const overlays = &fixture.overlays;
    fixture.model.name_prompt.begin(.create_workspace);
    try fixture.paint();
    try std.testing.expect(overlays.pointer(.{ .x = 1, .y = 1, .kind = .press, .button = 4 }).?.consumed);
    _ = fixture.model.name_prompt.apply(.cancel);
    try fixture.paint();
    try std.testing.expect(overlays.pointer(.{ .x = 1, .y = 1, .kind = .drag, .button = 32 }).?.consumed);
    try std.testing.expect(overlays.pointer(.{ .x = 1, .y = 1, .kind = .release, .button = 0 }).?.consumed);
    try std.testing.expect(overlays.pointer(.{ .x = 1, .y = 1, .kind = .move }) == null);

    fixture.model.name_prompt.begin(.create_workspace);
    try fixture.paint();
    _ = overlays.pointer(.{ .x = 1, .y = 1, .kind = .press });
    overlays.cancelPointer();
    _ = fixture.model.name_prompt.apply(.cancel);
    try fixture.paint();
    try std.testing.expect(overlays.pointer(.{ .x = 1, .y = 1, .kind = .move }) == null);
}

test "native goto picker uses bounded shared results and reuses warm glyphs without allocation" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    _ = try fixture.model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "alpha", .path = "/alpha", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "beta", .path = "/beta", .tab_count = 1 },
    } });
    fixture.model.name_prompt.begin(.goto_picker);
    _ = fixture.model.name_prompt.apply(.move_down);
    try fixture.paint();
    const first_count = fixture.renderer.quads.items().len;
    const first_version = fixture.renderer.atlas.?.version;
    const first_calls = fixture.renderer.atlas.?.shape_calls;
    const first_prompt = fixture.model.name_prompt.currentConst().?.*;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    fixture.renderer.atlas.?.allocator = allocator;
    fixture.renderer.quads.allocator = allocator;
    defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
    defer fixture.renderer.quads.allocator = std.testing.allocator;
    for (0..8) |_| {
        try fixture.paint();
    }

    try std.testing.expectEqual(first_count, fixture.renderer.quads.items().len);
    try std.testing.expectEqual(first_version, fixture.renderer.atlas.?.version);
    try std.testing.expectEqual(first_calls, fixture.renderer.atlas.?.shape_calls);
    try std.testing.expectEqualDeep(first_prompt, fixture.model.name_prompt.currentConst().?.*);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "native notification close has precedence and cannot leak its release to a pane" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const id = fixture.model.publishNotification(0, .{ .title = "Build complete", .message = "Open result", .target = .{ .select_tab = @enumFromInt(7) } }).id;
    _ = fixture.model.advanceNotifications(client.transition_duration_ns);
    try fixture.paint();
    try std.testing.expectEqual(@as(usize, 2), fixture.overlays.presented().notifications.count);
    const card = fixture.overlays.presented().notifications.hits[0].area;
    const close = fixture.overlays.presented().notifications.hits[1].area;
    const press = fixture.overlays.pointer(.{ .x = close.x, .y = close.y, .kind = .press }).?;
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = id }, press.intent);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .release }).?.consumed);
    const open = fixture.overlays.pointer(.{ .x = card.x + 1, .y = card.y + 1, .kind = .press }).?;
    try std.testing.expectEqualDeep(client.Intent{ .notification_activate = id }, open.intent);

    _ = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .release });
    fixture.model.name_prompt.begin(.create_workspace);
    try fixture.paint();
    const blocked = fixture.overlays.pointer(.{ .x = close.x, .y = close.y, .kind = .press }).?;
    try std.testing.expect(blocked.consumed and blocked.intent == .none);
}

test "native inspector wrapping handles unicode newlines and more than 64 thousand rows" {
    var lines: WrappedLines = .{ .text = "ab界e\u{301}\r\nx\n", .width = 4 };
    try std.testing.expectEqualStrings("ab界", lines.next().?);
    try std.testing.expectEqualStrings("e\u{301}", lines.next().?);
    try std.testing.expectEqualStrings("x", lines.next().?);
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
    const large: WrappedLines = .{ .text = "x\n" ** 65536, .width = 40 };
    try std.testing.expectEqual(@as(u32, 65537), large.count());
    const narrow: WrappedLines = .{ .text = "界界", .width = 1 };
    try std.testing.expectEqual(@as(u32, 2), narrow.count());
}

test "native history paints owned command output and exposes exact inspector scroll bounds" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const history = &fixture.model.history_palette;
    try history.prepare(std.testing.allocator);
    try std.testing.expect(history.beginPageRequest(1, .global));
    try std.testing.expect(history.acceptPageResult(.{
        .request_id = 1,
        .entries = &.{.{ .id = 9, .pane_id = @enumFromInt(2), .started_at_ms = 1700000000000, .duration_ns = 1800000000, .exit_code = 7, .status = .completed, .command = "zig build\x1b[2J", .cwd = "/work", .workspace_path = "/work" }},
        .snapshot_id = 9,
        .has_more = true,
        .now_ms = 1700000010000,
    }));
    history.expectOutput(.{ .request_id = 2, .id = 9 });
    try std.testing.expect(history.applyOutput(.{ .request_id = @enumFromInt(2), .id = 9, .content = "a\n" ** 1024, .truncated = false, .observed_bytes = 2048 }));
    fixture.model.name_prompt.begin(.history_palette);
    try fixture.paint();
    try std.testing.expect(Overlays.inspectionScrollLimit(fixture.projection()) == null);
    _ = fixture.model.name_prompt.apply(.toggle_inspection);
    _ = fixture.model.name_prompt.apply(.page_down);

    const limit = Overlays.inspectionScrollLimit(fixture.projection()).?;
    const area = fixture.overlays.presented().modal.?;
    try std.testing.expect(limit > 990);
    try fixture.paint();
    try std.testing.expect(fixture.overlays.presented().modal.?.h >= area.h);
    fixture.model.name_prompt.updateHistory(.{ .scroll_limit = limit });
    const expected = fixture.model.name_prompt.currentConst().?.*;
    try fixture.paint();
    try std.testing.expectEqualDeep(expected, fixture.model.name_prompt.currentConst().?.*);
    try std.testing.expectEqual(limit, Overlays.inspectionScrollLimit(fixture.projection()).?);

    const tiny = Modal.bounds(.{ .w = 5, .h = 2 }, .{ .w = 140, .h = 30 });
    try std.testing.expectEqualDeep(core.Rect{ .w = 5, .h = 2 }, tiny);
}

test "native suggestion states and thread surface stay within their assigned rectangles" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.suggest_palette);
    try fixture.paint();
    fixture.model.suggestion.expect(12);
    try fixture.paint();
    try std.testing.expect(fixture.model.suggestion.apply(.{ .request_id = @enumFromInt(12), .status = .ready, .text = "ls -la" }));
    try fixture.paint();

    fixture.renderer.quads.clear();
    var canvas = fixture.canvas();
    const area: core.Rect = .{ .x = 3, .y = 2, .w = 30, .h = 8 };
    try thread.paint(&canvas, area, .{ .pane_id = @enumFromInt(1), .agent = null, .composer = "a draft\x1b[2J" });
    const bounds = canvas.rect(area);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
        try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
        try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
    }
}
