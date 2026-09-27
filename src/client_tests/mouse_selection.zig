//! Mouse selection through the real client pointer routing and outbox.
const keyinput = @import("keyinput");

const core = @import("telar-core");
const data = @import("model");
const client_module = @import("telar-client");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");

test "mouse drag copies pane coordinates and keeps highlighting until typing" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, ClientHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello world", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, pane.id, client.geometry().area).?.content;
    const version = client.model.version();

    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 1, .y = content.y, .kind = .press });
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model).?.dragging);
    try std.testing.expect(data.copy_mode.currentProjection(&client.model).?.view.anchor == null);
    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 4, .y = content.y, .kind = .drag });
    try std.testing.expectEqual(version.copy + 2, client.model.version().copy);
    try harness.settleModelPresentation();
    try std.testing.expect(presentedCopy(&harness).?.view.selected(2, 10));

    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 4, .y = content.y, .kind = .release });
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

    _ = try client_module.key_routing.routeKeyInput(
        client,
        .{
            .key = try keyinput.chord.parseKey("x"),
        },
    );
    try std.testing.expect(data.copy_mode.currentProjection(&client.model) == null);
    try harness.settle();
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualStrings("x", input.pane_input.bytes);
}

test "selection focuses its pane and owns drags and release outside its borders" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const first = ClientHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    _ = try data.pane_split.commitSplit(&client.model, .{
        .split = .{ .target_pane = first, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area },
        .new_pane = second,
    });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(first));
    client.chrome = paneFocusChrome(client);
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.buffer.fill(client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    try harness.settleModelPresentation();
    const content = data.tab_layout.view(&client.model, model, second, client.geometry().area).?.content;

    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 2, .y = content.y + 1, .kind = .press });
    try std.testing.expectEqual(second, client.model.tabs.layout[model].focused().?);
    try std.testing.expectEqual(second, data.copy_mode.pointerSelection(&client.model).?.pane_id);
    // Even a child enabling mouse reporting mid-gesture cannot steal it.
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.mouse = .{ .tracking = .any, .sgr = true };
    _ = try client_module.pointer_routing.apply(client, .{ .x = 0, .y = 0, .kind = .drag });
    _ = try client_module.pointer_routing.apply(client, .{ .x = 0, .y = 0, .kind = .release });
    const selected = data.copy_mode.currentProjection(&client.model).?;
    try std.testing.expectEqual(second, selected.pane_id);
    try std.testing.expectEqual(@as(u16, 0), selected.view.cursor.x);
    try std.testing.expectEqual(@as(u32, 0), selected.view.cursor.y);
    try std.testing.expect(!data.copy_mode.pointerSelection(&client.model).?.dragging);
}

test "Shift selects child-tracked links instead of opening them or reporting the gesture" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, ClientHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .any, .sgr = true };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://example.com", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, pane.id, client.geometry().area).?.content;

    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x, .y = content.y, .kind = .press, .button = 4 });
    try std.testing.expect(!client.model.link_pointer.owned);
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model).?.dragging);
    // Modifier changes cannot transfer an already captured gesture.
    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 5, .y = content.y, .kind = .drag, .button = 32 });
    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x + 5, .y = content.y, .kind = .release });
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .copy_selection);
    try std.testing.expectEqual(@as(u16, 5), message.copy_selection.end_x);
}

test "retiring a selected pane consumes its remaining gesture instead of reporting to another pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const first = ClientHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = first, .new_pane = second, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(first));
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.buffer.fill(client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.buffer.area(), .{ .glyph = " ", .style = .{} });
    const content = data.tab_layout.view(&client.model, model, first, client.geometry().area).?.content;
    _ = try client_module.pointer_routing.apply(client, .{ .x = content.x, .y = content.y, .kind = .press });
    try std.testing.expect(data.copy_mode.release(&client.model, first));
    try std.testing.expect(data.tab_layout.removePane(&client.model, first));
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.mouse = .{ .tracking = .any, .sgr = true };
    const queued = client.model.to_runtime.len;
    const remaining = data.tab_layout.view(&client.model, model, second, client.geometry().area).?.content;

    _ = try client_module.pointer_routing.apply(client, .{ .x = remaining.x, .y = remaining.y, .kind = .drag });
    _ = try client_module.pointer_routing.apply(client, .{ .x = remaining.x, .y = remaining.y, .kind = .release });
    try std.testing.expect(data.copy_mode.pointerSelection(&client.model) == null);
    try std.testing.expectEqual(queued, client.model.to_runtime.len);
}

/// A chrome whose hit map focuses the pane under a press, as a window's
/// drawn pane regions do.
fn paneFocusChrome(client: *client_module.Client) client_module.HostChrome {
    return .{
        .context = client,
        .pointer_fn = focusPaneUnderPress,
        .inspection_scroll_limit_fn = noScrollLimit,
    };
}

fn focusPaneUnderPress(context: *anyopaque, event: keyinput.Mouse) client_module.ViewInteractionCommand {
    const client: *client_module.Client = @ptrCast(@alignCast(context));
    if (event.kind != .press) {
        return .{};
    }

    const slot = client.model.tabs.activeSlot() orelse return .{};
    for (data.tab_layout.snapshot(&client.model, slot, client.geometry().area).views()) |view| {
        if (view.content.contains(event.x, event.y)) {
            return .{
                .intent = .{
                    .focus_pane = view.pane_id,
                },
            };
        }
    }

    return .{};
}

fn noScrollLimit(_: *anyopaque) ?u32 {
    return null;
}

/// The copy selection a presentation of the current model carries.
fn presentedCopy(harness: *ClientHarness) ?client_module.CopyProjection {
    const model = &harness.client.model;

    return client_module.capture(model, .{ .geometry = data.workbench.region(model) }).copy;
}
