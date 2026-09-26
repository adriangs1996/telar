const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;

fn quotaGroup(content: *data.Content) !u8 {
    const group = try content.append(.{
        .kind = .group,
        .mark = .claude,
        .action = .{ .open_panel = 0 },
    });
    _ = try content.append(.{
        .kind = .meter,
        .parent = group,
        .text = "5h",
        .value = 220,
    });
    _ = try content.append(.{
        .kind = .meter_row,
        .parent = group,
        .in_tooltip = true,
        .text = "Session",
        .value = 220,
        .marker = 710,
    });

    return group;
}

fn configure(fixture: *Fixture) !void {
    const model = &fixture.session.gui.app.model;
    var left: data.Content = .{};
    _ = try left.append(.{
        .kind = .clock,
        .text = "%H:%M",
    });
    var right: data.Content = .{};
    _ = try quotaGroup(&right);
    model.bars.layout.bottom = .{ .{ .content = left }, .empty, .{ .content = right } };
    model.bars.layout.panel_count = 1;
    try model.bars.layout.panels[0].setName("usage");
    try model.bars.layout.panels[0].setTitle("Usage");
    try fixture.measure(.{ .width = 1200, .height = 700, .scale = 1 });
}

fn quadsAbove(fixture: *Fixture, y: f32) usize {
    var count: usize = 0;
    for (fixture.session.gui.renderer.quads.items()) |quad| {
        if (quad.y + quad.height <= y and quad.y > y - 400) {
            count += 1;
        }
    }

    return count;
}

test "a bar group with an action gets a target and hovering it shows its tooltip above the bar" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try configure(&fixture);
    const component: data.BarComponent = .{ .position = .bottom_right, .node = 0 };
    try fixture.paint(fixture.projection());

    const target = fixture.bandTarget(.{ .bar_component = component }).?;
    const band = fixture.chrome.presented().bands.status_bar;
    try std.testing.expect(target.y >= band.y and target.x + target.width <= band.x + band.width);
    try std.testing.expectEqualDeep(client.Intent{ .bar_component = component }, fixture.clickBand(target, 0).intent);

    const before = quadsAbove(&fixture, band.y);
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = target.x + 2, .y = target.y + 2 });
    try fixture.paint(fixture.projection());
    try std.testing.expect(quadsAbove(&fixture, band.y) > before);
}

test "an open panel floats above its component, registers its buttons and closes on a press outside" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try configure(&fixture);
    const model = &fixture.session.gui.app.model;
    const component: data.BarComponent = .{ .position = .bottom_right, .node = 0 };
    data.bar_panels.toggle(model, .{
        .target = .{ .configured = 0 },
        .anchor = component,
        .now_ns = 1,
    });
    var content: data.PanelContent = .{};
    _ = try content.append(.{
        .kind = .heading,
        .text = "On track",
    });
    _ = try content.append(.{
        .kind = .meter_row,
        .text = "Session",
        .detail = "Resets 13:20",
        .value = 220,
        .marker = 710,
    });
    const row = try content.append(.{ .kind = .actions });
    _ = try content.append(.{
        .kind = .button,
        .parent = row,
        .text = "Refresh",
        .action = .refresh_panel,
    });
    model.bars.panel.content = content;
    model.bars.panel.status = .ready;
    try fixture.paint(fixture.projection());

    const panel = fixture.chrome.presented().bar_panel;
    const anchor = fixture.bandTarget(.{ .bar_component = component }).?;
    const band = fixture.chrome.presented().bands.status_bar;
    try std.testing.expect(panel.width > 0 and panel.y + panel.height <= band.y);
    try std.testing.expectApproxEqAbs(anchor.x + anchor.width, panel.x + panel.width, 1);
    const button = fixture.bandTarget(.{ .panel_component = 3 }).?;
    try std.testing.expect(button.x >= panel.x and button.y + button.height <= panel.y + panel.height);
    try std.testing.expect(fixture.bandTarget(.close_panel) != null);

    const outside = fixture.chrome.bandPointer(.{ .kind = .press, .x = panel.x - 40, .y = panel.y + 10 }).?;
    try std.testing.expectEqualDeep(client.Intent.close_panel, outside.interaction.intent);
    const inside = fixture.chrome.bandPointer(.{ .kind = .move, .x = panel.x + 10, .y = panel.y + 60 }).?;
    try std.testing.expect(inside.interaction.consumed);
}

test "a narrow bar moves whole components to the overflow list" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try configure(&fixture);
    try fixture.measure(.{ .width = 90, .height = 400, .scale = 1 });
    try fixture.paint(fixture.projection());

    try std.testing.expect(fixture.bandTarget(.toggle_bar_overflow) != null);
    try std.testing.expect(fixture.chrome.presented().bar_overflow.count > 0);
}
