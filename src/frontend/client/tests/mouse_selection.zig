//! Mouse selection through the real client input, outbox and presenter ports.
const keyinput = @import("keyinput");

const core = @import("telar-core");
const data = @import("model");
const TestHarness = @import("TestHarness.zig");
const host_inputs = @import("../input/host_inputs.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");

test "mouse drag copies pane coordinates and keeps highlighting until typing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello world", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, pane.id, terminal.view.workbench()).?.content;
    const version = client.model.version();

    try host_inputs.mouse(terminal, .{ .x = content.x + 1, .y = content.y, .kind = .press });
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model).?.dragging);
    try std.testing.expect(data.copy_mode.currentProjection(&client.model).?.view.anchor == null);
    try host_inputs.mouse(terminal, .{ .x = content.x + 4, .y = content.y, .kind = .drag });
    try std.testing.expectEqual(version.copy + 2, client.model.version().copy);
    try std.testing.expect(terminal.presenter.compositor.copy == null);
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expect(terminal.presenter.compositor.copy.?.view.selected(2, 10));

    try host_inputs.mouse(terminal, .{ .x = content.x + 4, .y = content.y, .kind = .release });
    try std.testing.expect(!data.copy_mode.pointerSelection(&client.model).?.dragging);
    try std.testing.expect(data.copy_mode.currentProjection(&client.model).?.view.selected(4, 10));
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const copied = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualDeep(core.CopySelection{
        .pane_id = pane.id,
        .start_x = 1,
        .start_y = 10,
        .end_x = 4,
        .end_y = 10,
        .linewise = false,
    }, copied.copy_selection);

    try host_inputs.key(terminal, try keyinput.chord.parseKey("x"));
    try std.testing.expect(data.copy_mode.currentProjection(&client.model) == null);
    try harness.settle();
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualStrings("x", input.pane_input.bytes);
}

test "selection focuses its pane and owns drags and release outside its borders" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const first = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    _ = try data.pane_split.commitSplit(&client.model, .{
        .split = .{ .target_pane = first, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() },
        .new_pane = second,
    });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(first));
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.buffer.fill(client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    const content = data.tab_layout.view(&client.model, model, second, terminal.view.workbench()).?.content;

    try host_inputs.mouse(terminal, .{ .x = content.x + 2, .y = content.y + 1, .kind = .press });
    try std.testing.expectEqual(second, client.model.tabs.layout[model].focused().?);
    try std.testing.expectEqual(second, data.copy_mode.pointerSelection(&client.model).?.pane_id);
    // Even a child enabling mouse reporting mid-gesture cannot steal it.
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.mouse = .{ .tracking = .any, .sgr = true };
    try host_inputs.mouse(terminal, .{ .x = 0, .y = 0, .kind = .drag });
    try host_inputs.mouse(terminal, .{ .x = 0, .y = 0, .kind = .release });
    const selected = data.copy_mode.currentProjection(&client.model).?;
    try std.testing.expectEqual(second, selected.pane_id);
    try std.testing.expectEqual(@as(u16, 0), selected.view.cursor.x);
    try std.testing.expectEqual(@as(u32, 0), selected.view.cursor.y);
    try std.testing.expect(!data.copy_mode.pointerSelection(&client.model).?.dragging);
}

test "Shift selects child-tracked links instead of opening them or reporting the gesture" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .any, .sgr = true };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://example.com", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, pane.id, terminal.view.workbench()).?.content;

    try host_inputs.mouse(terminal, .{ .x = content.x, .y = content.y, .kind = .press, .button = 4 });
    try std.testing.expect(!client.model.link_pointer.owned);
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model).?.dragging);
    // Modifier changes cannot transfer an already captured gesture.
    try host_inputs.mouse(terminal, .{ .x = content.x + 5, .y = content.y, .kind = .drag, .button = 32 });
    try host_inputs.mouse(terminal, .{ .x = content.x + 5, .y = content.y, .kind = .release });
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .copy_selection);
    try std.testing.expectEqual(@as(u16, 5), message.copy_selection.end_x);
}

test "retiring a selected pane consumes its remaining gesture instead of reporting to another pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const first = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = first, .new_pane = second, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(first));
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.buffer.fill(client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, first, terminal.view.workbench()).?.content;
    try host_inputs.mouse(terminal, .{ .x = content.x, .y = content.y, .kind = .press });
    try std.testing.expect(data.copy_mode.release(&client.model, first));
    try std.testing.expect(data.tab_layout.removePane(&client.model, first));
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.mouse = .{ .tracking = .any, .sgr = true };
    const queued = client.model.to_runtime.len;
    const remaining = data.tab_layout.view(&client.model, model, second, terminal.view.workbench()).?.content;

    try host_inputs.mouse(terminal, .{ .x = remaining.x, .y = remaining.y, .kind = .drag });
    try host_inputs.mouse(terminal, .{ .x = remaining.x, .y = remaining.y, .kind = .release });
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model) == null);
    try std.testing.expectEqual(queued, client.model.to_runtime.len);
}
