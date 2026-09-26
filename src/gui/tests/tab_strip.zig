//! The tab strip and the workspace rail as a person sees them: which tab is
//! lifted, how tabs give up width, what a click may move and what the rail
//! says about the project under the pointer.
const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const Rect = gfx.Rect;
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");

const long_label = "a tab with a deliberately long label";

// Every tab, the session's own included, carries the same long label.
fn addTabs(fixture: *Fixture, count: usize) !void {
    const model = &fixture.session.gui.app.model;
    _ = try data.tab_rename.rename(model, Session.location.tab_id, long_label);
    for (1..count) |index| {
        _ = try data.tab_creation.add(
            model,
            .{
                .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(index + 1) },
                .position = @intCast(index),
                .label = long_label,
                .root_pane_id = @enumFromInt(index + 20),
            },
            model.host.host_size,
        );
    }

    _ = data.tab_selection.select(model, Session.location.tab_id);
}

fn tabId(index: usize) core.TabId {
    return if (index == 0) Session.location.tab_id else @enumFromInt(index + 1);
}

fn inside(quad: Quad, bounds: Rect) bool {
    return quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height;
}

fn filled(quads: []const Quad, bounds: Rect) bool {
    for (quads) |quad| {
        if (quad.radius > 0 and quad.border == 0 and quad.a == 1 and quad.width == bounds.width and quad.height == bounds.height and quad.x == bounds.x and quad.y == bounds.y) {
            return true;
        }
    }

    return false;
}

// Translucent rounded quads that spread past a tab: its shadow.
fn shadowed(quads: []const Quad, bounds: Rect) bool {
    for (quads) |quad| {
        const around = quad.x < bounds.x and quad.x + quad.width > bounds.x + bounds.width and quad.y + quad.height > bounds.y + bounds.height;
        if (quad.radius > 0 and quad.a > 0 and quad.a < 1 and quad.border == 0 and around) {
            return true;
        }
    }

    return false;
}

fn colored(quads: []const Quad, bounds: Rect, color: cellgrid.Color) bool {
    const rgb = color.rgbChannels().?;
    for (quads) |quad| {
        const matches = @abs(quad.r - @as(f32, @floatFromInt(rgb[0])) / 255) < 0.01 and @abs(quad.g - @as(f32, @floatFromInt(rgb[1])) / 255) < 0.01 and @abs(quad.b - @as(f32, @floatFromInt(rgb[2])) / 255) < 0.01;
        if (inside(quad, bounds) and matches and quad.a > 0) {
            return true;
        }
    }

    return false;
}

fn tabBounds(fixture: *Fixture, count: usize, into: []?Rect) void {
    for (0..count) |index| {
        into[index] = fixture.bandTarget(.{ .select_tab = tabId(index) });
    }
}

fn settle(fixture: *Fixture) !void {
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(fixture.projection());
}

test "only the selected tab is filled and lifted by a translucent shadow" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try addTabs(&fixture, 3);
    try fixture.showSidebar(false);
    try settle(&fixture);
    const quads = fixture.session.gui.renderer.quads.items();
    const selected = fixture.bandTarget(.{ .select_tab = tabId(0) }).?;
    const other = fixture.bandTarget(.{ .select_tab = tabId(1) }).?;
    try std.testing.expect(filled(quads, selected));
    try std.testing.expect(shadowed(quads, selected));
    try std.testing.expect(!filled(quads, other));
    try std.testing.expect(!shadowed(quads, other));

    // Hover gives a quiet fill and no shadow.
    fixture.chrome.hovered = .{ .intent = .{ .select_tab = tabId(1) } };
    try fixture.paint(fixture.projection());
    try std.testing.expect(filled(fixture.session.gui.renderer.quads.items(), other));
    try std.testing.expect(!shadowed(fixture.session.gui.renderer.quads.items(), other));
}

test "narrower strips compress tabs, keep attention visible and hide the farthest behind a counter" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const count = 12;
    try addTabs(&fixture, count);
    const model = &fixture.session.gui.app.model;
    _ = data.tab_selection.select(model, tabId(6));
    try fixture.showSidebar(false);
    var agents: data.AgentSnapshot = .{};
    const waiting: core.TabLocation = .{ .workspace = Session.location.workspace, .tab_id = tabId(11) };
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = @enumFromInt(31), .pane_generation = 1 }, .location = waiting, .pane_index = 1, .provider = .codex, .status = .blocked }} });
    const palette = model.theme.palette;
    var previous_total: f32 = std.math.inf(f32);
    var hid = false;
    for ([_]u32{ 2400, 1400, 900, 600, 420 }) |width| {
        try fixture.measure(.{ .width = width, .height = 600, .scale = 1 });
        var projection = fixture.projection();
        projection.agents = &agents;
        fixture.chrome.now_ns += std.time.ns_per_s;
        try fixture.paint(projection);
        const top = fixture.chrome.presented().bands.top_bar;
        const quads = fixture.session.gui.renderer.quads.items();
        const active = fixture.bandTarget(.{ .select_tab = tabId(6) }).?;
        try std.testing.expect(active.x >= top.x and active.x + active.width <= top.x + top.width);

        var total: f32 = 0;
        var visible: usize = 0;
        var last_right: f32 = 0;
        for (0..count) |index| {
            const bounds = fixture.bandTarget(.{ .select_tab = tabId(index) }) orelse continue;
            if (bounds.width == fixture.session.gui.renderer.chrome.px(36) and index != 6) {
                // A counter carries the identity of the nearest hidden tab.
                continue;
            }

            visible += 1;
            total += bounds.width;
            try std.testing.expect(bounds.x >= last_right);
            last_right = bounds.x + bounds.width;
        }

        try std.testing.expect(total <= previous_total);
        previous_total = total;
        if (fixture.bandTarget(.{ .select_tab = tabId(11) })) |bounds| {
            // Visible or behind the counter, the waiting agent keeps its dot.
            try std.testing.expect(colored(quads, bounds, palette.yellow));
        }

        if (visible < count) {
            hid = true;
            const plus = fixture.bandTarget(.create_tab).?;
            try std.testing.expect(plus.x >= last_right);
        }
    }

    try std.testing.expect(hid);
}

test "the strip keeps its widths while the pointer rests on it and follows the selection once it leaves" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const count = 5;
    try addTabs(&fixture, count);
    try fixture.showSidebar(false);
    try fixture.measure(.{ .width = 1000, .height = 600, .scale = 1 });
    try settle(&fixture);
    var before: [count]?Rect = undefined;
    tabBounds(&fixture, count, &before);
    const selected_width = before[0].?.width;
    try std.testing.expect(before[3].?.width < selected_width);

    // The pointer rests on the fourth tab and selects it.
    const target = before[3].?;
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = target.x + 2, .y = target.y + 2 });
    try std.testing.expect(fixture.chrome.pointer_in_tabs);
    _ = data.tab_selection.select(&fixture.session.gui.app.model, tabId(3));
    try settle(&fixture);
    var frozen: [count]?Rect = undefined;
    tabBounds(&fixture, count, &frozen);
    for (before, frozen) |old, new| {
        try std.testing.expectEqualDeep(old, new);
    }

    // Leaving the strip lets the new selection take its room.
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = target.x + 2, .y = target.y + 200 });
    fixture.chrome.leavePointer();
    try std.testing.expect(!fixture.chrome.pointer_in_tabs);
    try settle(&fixture);
    const grown = fixture.bandTarget(.{ .select_tab = tabId(3) }).?;
    try std.testing.expect(grown.width > target.width);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = tabId(0) }).?.width < selected_width);
}

test "truncated captions fade out instead of ending mid-glyph" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const count = 5;
    try addTabs(&fixture, count);
    try fixture.showSidebar(false);
    try fixture.measure(.{ .width = 1000, .height = 600, .scale = 1 });
    try settle(&fixture);
    const quads = fixture.session.gui.renderer.quads.items();
    const truncated = fixture.bandTarget(.{ .select_tab = tabId(2) }).?;
    var faded: usize = 0;
    for (quads) |quad| {
        if (inside(quad, truncated) and quad.radius == 0 and quad.a > 0 and quad.a < 1) {
            faded += 1;
        }
    }

    try std.testing.expect(faded > 0);
}

test "the rail names the project under the pointer beside the rail" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "freya", .path = "/freya", .tab_count = 3 },
    } });
    try fixture.paint(fixture.projection());
    const rail = fixture.band();
    const mark = fixture.bandTarget(.{ .select_workspace = @enumFromInt(9) }).?;
    const beside: Rect = .{ .x = rail.x + rail.width, .y = mark.y - 4, .width = 400, .height = mark.height + 8 };
    const before = fixture.session.gui.renderer.quads.items();
    var tooltip_before = false;
    for (before) |quad| {
        tooltip_before = tooltip_before or (inside(quad, beside) and quad.radius > 0 and quad.a == 1 and quad.border == 0);
    }

    try std.testing.expect(!tooltip_before);
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = mark.x + 4, .y = mark.y + 4 });
    try fixture.paint(fixture.projection());
    var surface: ?Quad = null;
    var glyphs: usize = 0;
    for (fixture.session.gui.renderer.quads.items()) |quad| {
        if (!inside(quad, beside)) {
            continue;
        }

        if (quad.radius > 0 and quad.a == 1 and quad.border == 0) {
            surface = quad;
        } else if (quad.radius == 0 and quad.texture != gfx.Quad.sprite_texture) {
            glyphs += 1;
        }
    }

    const box = surface orelse return error.MissingTooltip;
    try std.testing.expectApproxEqAbs(mark.y + mark.height / 2, box.y + box.height / 2, 1);
    try std.testing.expect(glyphs >= "freya".len);
    try std.testing.expectEqualDeep(client.Intent{ .select_workspace = @enumFromInt(9) }, fixture.clickBand(mark, 0).intent);
}

test "a ready session title renames an automatic tab and widens it" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const tab = model.tabs.find(Session.location.tab_id).?;
    model.tabs.setLabel(tab, "");
    _ = model.panes.find(Session.pane_id).?.setForegroundName("claude");
    try settle(&fixture);
    const plain = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    var agents: data.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .claude, .status = .ready, .session_title = "Migrate the payment webhooks", .title_state = .ready }} });
    model.agent_snapshot = agents;
    try settle(&fixture);
    const titled = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    try std.testing.expect(titled.width > plain.width);
    var storage: [data.tab_label.caption_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Migrate the payment webhooks", data.tab_label.caption(model, tab, &storage));
}

test "a frozen strip still reveals a selection made from the keyboard" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const count = 12;
    try addTabs(&fixture, count);
    try fixture.showSidebar(false);
    try fixture.measure(.{ .width = 420, .height = 600, .scale = 1 });
    try settle(&fixture);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = tabId(0) }) != null);
    const first = fixture.bandTarget(.{ .select_tab = tabId(0) }).?;
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = first.x + 2, .y = first.y + 2 });
    _ = data.tab_selection.select(&fixture.session.gui.app.model, tabId(count - 1));
    try settle(&fixture);
    const revealed = fixture.bandTarget(.{ .select_tab = tabId(count - 1) }).?;
    try std.testing.expect(revealed.width > fixture.session.gui.renderer.chrome.px(36));
    try std.testing.expect(fixture.chrome.pointer_in_tabs);
}
