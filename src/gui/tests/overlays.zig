const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const Modal = @import("../widgets/overlays/Modal.zig");
const Overlays = @import("../widgets/overlays/Overlays.zig");
const WrappedLines = @import("../widgets/overlays/WrappedLines.zig");
const ThreadPane = @import("../widgets/ThreadPane.zig");

test "native history keeps the visible page while a replacement query is pending" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const history = &fixture.model.history_palette;
    try history.prepare(std.testing.allocator);
    const entries = [_]core.HistoryEntry{.{ .id = 9, .pane_id = @enumFromInt(2), .started_at_ms = 1000, .duration_ns = 1000000, .exit_code = 0, .status = .completed, .command = "zig build", .cwd = "/work", .workspace_path = "/work" }};
    try std.testing.expect(history.beginPageRequest(1, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 1, .entries = &entries, .snapshot_id = 9, .has_more = false, .now_ms = 1000 }));
    fixture.model.name_prompt.begin(.history_palette);
    try fixture.paint();
    const visible = try historyRows(fixture);
    defer std.testing.allocator.free(visible);

    try std.testing.expect(history.beginPageRequest(2, .global));
    try fixture.paint();
    try expectHistoryRows(fixture, visible);
    try std.testing.expect(history.commandAt(0) == null);

    try std.testing.expect(!history.acceptPageResult(.{ .request_id = 1, .entries = &.{}, .snapshot_id = 9, .has_more = false, .now_ms = 1000 }));
    try fixture.paint();
    try expectHistoryRows(fixture, visible);
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 2, .entries = &.{}, .snapshot_id = 9, .has_more = false, .now_ms = 1000 }));
    try fixture.paint();
    const empty = try historyRows(fixture);
    defer std.testing.allocator.free(empty);
    try std.testing.expect(visible.len != empty.len);
    try std.testing.expect(history.beginPageRequest(3, .global));
    try fixture.paint();
    try expectHistoryRows(fixture, empty);
}

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
    const close = fixture.overlays.presented().notifications.hits[1].bounds;
    _ = fixture.model.dismissNotification(first, client.transition_duration_ns);
    _ = fixture.model.advanceNotifications(client.transition_duration_ns * 2);
    const second = fixture.model.publishNotification(client.transition_duration_ns * 2, .{ .title = "Next", .message = "Prepared" }).id;
    _ = fixture.model.advanceNotifications(client.transition_duration_ns * 3);
    try fixture.prepare();
    try std.testing.expectEqual(close, fixture.overlays.prepared().notifications.hits[1].bounds);
    const mouse: @import("../input/PointerEvent.zig") = .{ .x = close.x, .y = close.y, .kind = .press };
    const release: @import("../input/PointerEvent.zig") = .{ .x = 0, .y = 0, .kind = .release };
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = first }, fixture.pointer(mouse).intent);
    _ = fixture.pointer(release);
    fixture.present(false);
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = first }, fixture.pointer(mouse).intent);
    _ = fixture.pointer(release);

    try fixture.prepare();
    fixture.present(true);
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = second }, fixture.pointer(mouse).intent);
}

test "native modal geometry clips every glyph on tiny hosts and preserves prompt state" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.create_workspace);
    _ = fixture.model.name_prompt.apply(.{ .insert = "A workspace that does not fit" });

    for ([_][2]u32{ .{ 24, 24 }, .{ 90, 60 }, .{ 240, 120 }, .{ 360, 300 }, .{ 1600, 1200 } }) |size| {
        fixture.size = try fixture.renderer.measure(.{ .width = size[0], .height = size[1], .scale = 1 });
        try fixture.paint();
        for (fixture.renderer.quads.items()) |quad| {
            try std.testing.expect(quad.x >= 0 and quad.y >= 0);
            try std.testing.expect(quad.x + quad.width <= @as(f32, @floatFromInt(size[0])) + 0.001);
            try std.testing.expect(quad.y + quad.height <= @as(f32, @floatFromInt(size[1])) + 0.001);
        }

        const bounds = fixture.overlays.presented().native_modal.?;
        const registry = fixture.widgets.dispatcher.maps.presented();
        for (registry.targets[0..registry.len]) |target| {
            try std.testing.expect(target.bounds.x >= bounds.x and target.bounds.y >= bounds.y);
            try std.testing.expect(target.bounds.x + target.bounds.width <= bounds.x + bounds.width + 0.001);
            try std.testing.expect(target.bounds.y + target.bounds.height <= bounds.y + bounds.height + 0.001);
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
    const card = fixture.overlays.presented().notifications.hits[0].bounds;
    const close = fixture.overlays.presented().notifications.hits[1].bounds;
    const press = fixture.pointer(.{ .x = close.x, .y = close.y, .kind = .press });
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = id }, press.intent);
    try std.testing.expect(fixture.pointer(.{ .x = 0, .y = 0, .kind = .release }).consumed);
    const open = fixture.pointer(.{ .x = card.x + 1, .y = card.y + 1, .kind = .press });
    try std.testing.expectEqualDeep(client.Intent{ .notification_activate = id }, open.intent);

    _ = fixture.pointer(.{ .x = 0, .y = 0, .kind = .release });
    fixture.model.name_prompt.begin(.create_workspace);
    try fixture.paint();
    const blocked = fixture.pointer(.{ .x = close.x, .y = close.y, .kind = .press });
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
    try std.testing.expect(fixture.overlays.inspectionScrollLimit(fixture.projection()) == null);
    _ = fixture.model.name_prompt.apply(.toggle_inspection);
    _ = fixture.model.name_prompt.apply(.page_down);

    const limit = fixture.overlays.inspectionScrollLimit(fixture.projection()).?;
    const area = fixture.overlays.presented().modal.?;
    try std.testing.expect(limit > 990);
    try fixture.paint();
    try std.testing.expect(fixture.overlays.presented().modal.?.h >= area.h);
    fixture.model.name_prompt.updateHistory(.{ .scroll_limit = limit });
    const expected = fixture.model.name_prompt.currentConst().?.*;
    try fixture.paint();
    try std.testing.expectEqualDeep(expected, fixture.model.name_prompt.currentConst().?.*);
    try std.testing.expectEqual(limit, fixture.overlays.inspectionScrollLimit(fixture.projection()).?);

    const tiny = Modal.bounds(.{ .w = 5, .h = 2 }, .{ .w = 140, .h = 30 });
    try std.testing.expectEqualDeep(core.Rect{ .w = 5, .h = 2 }, tiny);
}

test "native new-context form paints both fields, the completion list and the confirmation inside its modal" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.create_workspace);
    _ = fixture.model.name_prompt.apply(.{ .insert = "agents" });
    _ = fixture.model.name_prompt.apply(.tab);
    _ = fixture.model.name_prompt.apply(.{ .insert = "/work/te" });
    var result: client.PathCompletionResult = .{};
    try result.setBase("/work");
    try result.append("telar");
    try result.append("tests");
    fixture.model.path_completion.begin();
    fixture.model.path_completion.expect(@enumFromInt(1));
    try std.testing.expect(fixture.model.path_completion.apply(@enumFromInt(1), .{ .query = "/work/te", .result = &result }));
    _ = fixture.model.name_prompt.apply(.move_down);
    try fixture.paint();

    const bounds = fixture.overlays.presented().native_modal.?;
    try std.testing.expectEqual(@as(f32, 520), bounds.width);
    const with_list = fixture.renderer.quads.items().len;
    var editor_count: usize = 0;
    var folder_count: usize = 0;
    const registry = fixture.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        editor_count += @intFromBool(target.action == .text_field);
        folder_count += @intFromBool(target.action == .complete_path);
        try std.testing.expect(target.bounds.x >= bounds.x and target.bounds.y >= bounds.y);
        try std.testing.expect(target.bounds.x + target.bounds.width <= bounds.x + bounds.width);
        try std.testing.expect(target.bounds.y + target.bounds.height <= bounds.y + bounds.height);
    }
    try std.testing.expectEqual(@as(usize, 2), editor_count);
    try std.testing.expectEqual(@as(usize, 2), folder_count);
    const directory_y = fixture.widgets.editors.presented().items[1].bounds.y;
    _ = fixture.model.name_prompt.apply(.back_tab);
    try fixture.paint();
    try std.testing.expectEqual(bounds.y, fixture.overlays.presented().native_modal.?.y);
    try std.testing.expectEqual(directory_y, fixture.widgets.editors.presented().items[1].bounds.y);
    _ = fixture.model.name_prompt.apply(.tab);
    try fixture.paint();
    try std.testing.expect(with_list > 10);
    const press = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press }).?;
    try std.testing.expect(press.consumed);
    try std.testing.expect(press.intent == .none);
    _ = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .release });

    fixture.model.name_prompt.requestDirectoryConfirmation();
    fixture.model.path_completion.invalidate();
    try fixture.paint();
    const confirmed = fixture.widgets.dispatcher.maps.presented();
    for (confirmed.targets[0..confirmed.len]) |target| {
        try std.testing.expect(target.action != .complete_path);
        if (target.action == .prompt and target.action.prompt == .submit) {
            try std.testing.expectEqualStrings("Create folder & context", target.label[0..target.label_len]);
        }
    }
    try std.testing.expectEqualStrings("agents", fixture.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqualStrings("/work/te", fixture.model.name_prompt.currentConst().?.directory.text());
    try std.testing.expect(fixture.model.name_prompt.currentConst().?.form().?.confirm_create);
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
    try (ThreadPane{ .area = area, .thread = .{ .pane_id = @enumFromInt(1), .agent = null, .composer = "a draft\x1b[2J" } }).draw(&canvas);
    const bounds = canvas.rect(area);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
        try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
        try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
    }
}

test "native context layout ignores terminal cell geometry and reuses its warm draw" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.create_workspace);
    _ = fixture.model.name_prompt.apply(.{ .insert = "agents" });
    try fixture.paint();
    const bounds = fixture.overlays.presented().native_modal.?;
    const fields = fixture.widgets.editors.presented().*;
    fixture.renderer.metrics.cell_width += 5;
    fixture.renderer.metrics.cell_height += 10;
    fixture.size.cols = 25;
    fixture.size.rows = 12;
    try fixture.paint();
    try std.testing.expectEqualDeep(bounds, fixture.overlays.presented().native_modal.?);
    try std.testing.expectEqualDeep(fields, fixture.widgets.editors.presented().*);
    const calls = fixture.renderer.atlas.?.shape_calls;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.renderer.atlas.?.allocator = failing.allocator();
    fixture.renderer.quads.allocator = failing.allocator();
    defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
    defer fixture.renderer.quads.allocator = std.testing.allocator;
    for (0..8) |_| {
        try fixture.paint();
    }
    try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

fn historyRows(fixture: *Fixture) ![]@import("../render/Quad.zig").Quad {
    const canvas = fixture.canvas();
    const layout = @import("../widgets/overlays/HistoryModalLayout.zig").measure(@import("../widgets/overlays/HistoryModalMetrics.zig").fromCanvas(&canvas), false);
    var result: std.ArrayList(@import("../render/Quad.zig").Quad) = .empty;
    errdefer result.deinit(std.testing.allocator);
    for (fixture.renderer.quads.items()) |quad| {
        if (quad.y >= layout.results.y and quad.y + quad.height <= layout.results.y + layout.results.height) {
            try result.append(std.testing.allocator, quad);
        }
    }

    return result.toOwnedSlice(std.testing.allocator);
}

fn expectHistoryRows(fixture: *Fixture, expected: []const @import("../render/Quad.zig").Quad) !void {
    const actual = try historyRows(fixture);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualDeep(expected, actual);
}
