const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarnessType = @import("TestHarness.zig");
const PaneDescriptorType = @import("telar-core").PaneDescriptor;
const client_actions = @import("telar-client").controllers.actions;
const encodeTabSnapshot_module = @import("telar-core").encodeTabSnapshot;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const PaneTargetType = @import("telar-core").PaneTarget;
const encodePaneOpened_module = @import("telar-core").encodePaneOpened;
const InputHandler = @import("../resources/InputHandler.zig");
const parseKey_module = @import("telar-client").parseKey;
const FullscreenReattachment = @This();

harness: *TestHarnessType,

pub fn selectTab(scenario: FullscreenReattachment, index: u8, panes: []const PaneDescriptorType) !void {
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
    const snapshot = try encodeTabSnapshot_module(&buffer, .{
        .request_id = request.request_id,
        .location = request.location,
        .panes = panes,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));
    try scenario.confirmAttachment(client.model.workspace.active().?.model.layout.focused().?);
}

pub fn confirmAttachment(scenario: FullscreenReattachment, pane_id: PaneIdType) !void {
    const client = scenario.harness.client;
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, pane_id));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(PaneTargetType{ .pane = pane_id }, message.open_pane.target);
    try std.testing.expectEqualDeep(
        client.model.workspace.active().?.model.contentSize(pane_id, host(client).view.workbench()).?,
        message.open_pane.size,
    );
    const opened = try encodePaneOpened_module(&buffer, .{
        .request_id = message.open_pane.request_id,
        .pane_id = pane_id,
        .location = client.model.activeTabLocation().?,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));
    try std.testing.expect(client.model.workspace.findPane(pane_id).?.attached);
}

pub fn expectInput(scenario: FullscreenReattachment, pane_id: PaneIdType) !void {
    var handler: InputHandler = .{ .client = scenario.harness.client };
    try std.testing.expectEqual(pane_id, handler.client.model.planPaneInput(.focused).?.pane_id);
    try handler.key(try parseKey_module("x"));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(pane_id, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", message.pane_input.bytes);
}
