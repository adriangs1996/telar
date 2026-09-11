const FullscreenReattachment = @This();
const source_namespace = @import("pane_lifecycle.zig");
const client_actions = @import("../controllers/input/actions.zig");
const server_messages = @import("../entrypoints/runtime_messages.zig");
const std = @import("std");
const InputHandler = @import("../resources/InputHandler.zig");
harness: *source_namespace.TestHarness,

pub fn selectTab(scenario: FullscreenReattachment, index: u8, panes: []const source_namespace.schema.PaneDescriptor) !void {
    const client = scenario.harness.client;
    _ = try client_actions.apply(client, .{ .select_tab = index });
    try scenario.harness.settle();
    var buffer: [512]u8 = undefined;
    const request = request: while (true) {
        switch (try scenario.harness.nextClientMessage(&buffer)) {
            .detach_pane => {},
            .request_tab_snapshot => |request| break :request request,
            else => return error.UnexpectedClientMessage,
        }
    };
    const snapshot = try source_namespace.schema.encodeTabSnapshot(&buffer, .{
        .request_id = request.request_id,
        .location = request.location,
        .panes = panes,
    });
    _ = try server_messages.handleServerMessage(client, try source_namespace.schema.decodeServer(snapshot));
    try scenario.confirmAttachment(client.model.workspace.active().?.model.layout.focused().?);
}

pub fn confirmAttachment(scenario: FullscreenReattachment, pane_id: source_namespace.schema.PaneId) !void {
    const client = scenario.harness.client;
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, pane_id));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(source_namespace.schema.PaneTarget{ .pane = pane_id }, message.open_pane.target);
    try std.testing.expectEqualDeep(
        client.model.workspace.active().?.model.contentSize(pane_id, client.view.workbench()).?,
        message.open_pane.size,
    );
    const opened = try source_namespace.schema.encodePaneOpened(&buffer, .{
        .request_id = message.open_pane.request_id,
        .pane_id = pane_id,
        .location = client.model.activeTabLocation().?,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try source_namespace.schema.decodeServer(opened));
    try std.testing.expect(client.model.workspace.findPane(pane_id).?.attached);
}

pub fn expectInput(scenario: FullscreenReattachment, pane_id: source_namespace.schema.PaneId) !void {
    var handler: InputHandler = .{ .client = scenario.harness.client };
    try std.testing.expectEqual(pane_id, handler.client.model.planPaneInput(.focused).?.pane_id);
    try handler.key(try source_namespace.keybind.parseKey("x"));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(pane_id, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", message.pane_input.bytes);
}
