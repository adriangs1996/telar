//! Mouse selection through the real client input, outbox and presenter ports.

const std = @import("std");
const core = @import("telar-core");
const keybind = @import("telar-client").input.keybind;
const TestHarness = @import("support.zig").TestHarness;
const InputHandler = @import("../resources/InputHandler.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");

const schema = core.schema;

test "mouse drag copies pane coordinates and keeps highlighting until typing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.activeTabModel().?;
    const pane = model.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello world", .style = .{} });
    const content = model.viewForPane(pane.id, client.view.workbench()).?.content;
    var handler: InputHandler = .{ .client = client };
    const version = client.model.version();

    try handler.mouse(.{ .x = content.x + 1, .y = content.y, .kind = .press });
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.pointerSelection().?.dragging);
    try std.testing.expect(client.model.copyModeProjection().?.view.anchor == null);
    try handler.mouse(.{ .x = content.x + 4, .y = content.y, .kind = .drag });
    try std.testing.expectEqual(version.copy + 2, client.model.version().copy);
    try std.testing.expect(client.presenter.compositor.copy == null);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expect(client.presenter.compositor.copy.?.view.selected(2, 10));

    try handler.mouse(.{ .x = content.x + 4, .y = content.y, .kind = .release });
    try std.testing.expect(!client.model.pointerSelection().?.dragging);
    try std.testing.expect(client.model.copyModeProjection().?.view.selected(4, 10));
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const copied = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualDeep(schema.CopySelection{
        .pane_id = pane.id,
        .start_x = 1,
        .start_y = 10,
        .end_x = 4,
        .end_y = 10,
        .linewise = false,
    }, copied.copy_selection);

    try handler.key(try keybind.parseKey("x"));
    try std.testing.expect(client.model.copyModeProjection() == null);
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
    const model = client.model.activeTabModel().?;
    const first = TestHarness.bootstrap_pane;
    const second: schema.PaneId = @enumFromInt(20);
    _ = try client.model.commitPaneSplit(.{
        .split = .{ .target_pane = first, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() },
        .new_pane = second,
    });
    try std.testing.expect(model.focusPane(first));
    model.find(second).?.buffer.fill(model.find(second).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const content = model.viewForPane(second, client.view.workbench()).?.content;
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(.{ .x = content.x + 2, .y = content.y + 1, .kind = .press });
    try std.testing.expectEqual(second, model.layout.focused().?);
    try std.testing.expectEqual(second, client.model.pointerSelection().?.pane_id);
    // Even a child enabling mouse reporting mid-gesture cannot steal it.
    model.find(second).?.mouse = .{ .tracking = .any, .sgr = true };
    try handler.mouse(.{ .x = 0, .y = 0, .kind = .drag });
    try handler.mouse(.{ .x = 0, .y = 0, .kind = .release });
    const selected = client.model.copyModeProjection().?;
    try std.testing.expectEqual(second, selected.pane_id);
    try std.testing.expectEqual(@as(u16, 0), selected.view.cursor.x);
    try std.testing.expectEqual(@as(u32, 0), selected.view.cursor.y);
    try std.testing.expect(!client.model.pointerSelection().?.dragging);
}

test "Shift selects child-tracked links instead of opening them or reporting the gesture" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.activeTabModel().?;
    const pane = model.find(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .any, .sgr = true };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://example.com", .style = .{} });
    const content = model.viewForPane(pane.id, client.view.workbench()).?.content;
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(.{ .x = content.x, .y = content.y, .kind = .press, .button = 4 });
    try std.testing.expect(!client.link_pointer.owned);
    try std.testing.expect(client.model.pointerSelection().?.dragging);
    // Modifier changes cannot transfer an already captured gesture.
    try handler.mouse(.{ .x = content.x + 5, .y = content.y, .kind = .drag, .button = 32 });
    try handler.mouse(.{ .x = content.x + 5, .y = content.y, .kind = .release });
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
    const model = client.model.activeTabModel().?;
    const first = TestHarness.bootstrap_pane;
    const second: schema.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
    try std.testing.expect(model.focusPane(first));
    model.find(first).?.buffer.fill(model.find(first).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    const content = model.viewForPane(first, client.view.workbench()).?.content;
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = content.x, .y = content.y, .kind = .press });
    try std.testing.expect(client.model.releaseCopyMode(first));
    try std.testing.expect(model.removePane(first));
    model.find(second).?.mouse = .{ .tracking = .any, .sgr = true };
    const queued = client.runtime_transport.outbox.len;
    const remaining = model.viewForPane(second, client.view.workbench()).?.content;

    try handler.mouse(.{ .x = remaining.x, .y = remaining.y, .kind = .drag });
    try handler.mouse(.{ .x = remaining.x, .y = remaining.y, .kind = .release });
    try std.testing.expect(client.model.pointerSelection() == null);
    try std.testing.expectEqual(queued, client.runtime_transport.outbox.len);
}
