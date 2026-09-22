const core = @import("telar-core");
const data = @import("model");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarnessType = @import("TestHarness.zig");
const std = @import("std");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const FullscreenReattachment = @This();

harness: *TestHarnessType,

pub fn selectTab(scenario: FullscreenReattachment, index: u8, panes: []const core.PaneDescriptor) !void {
    const client = scenario.harness.client;
    _ = try client.executeAction(
        .{
            .select_tab = index,
        },
        .effect,
    );
    try scenario.harness.settle();
    var buffer: [512]u8 = undefined;
    const request = request: while (true) {
        switch (try scenario.harness.nextClientMessage(&buffer)) {
            .detach_pane => {},
            .request_tab_snapshot => |request| break :request request,
            else => return error.UnexpectedClientMessage,
        }
    };
    const snapshot = try core.encodeTabSnapshot(&buffer, .{
        .request_id = request.request_id,
        .location = request.location,
        .panes = panes,
    });
    _ = try client.handleServerMessage(try core.decodeServer(snapshot));
    try scenario.confirmAttachment(client.model.workspace.active().?.model.layout.focused().?);
}

pub fn confirmAttachment(scenario: FullscreenReattachment, pane_id: core.PaneId) !void {
    const client = scenario.harness.client;
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, pane_id));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = pane_id }, message.open_pane.target);
    try std.testing.expectEqualDeep(
        client.model.workspace.active().?.model.contentSize(pane_id, TerminalClient.of(client).view.workbench()).?,
        message.open_pane.size,
    );
    const opened = try core.encodePaneOpened(&buffer, .{
        .request_id = message.open_pane.request_id,
        .pane_id = pane_id,
        .location = client.model.activeTabLocation().?,
        .created = false,
    });
    _ = try client.handleServerMessage(try core.decodeServer(opened));
    try std.testing.expect(client.model.workspace.findPane(pane_id).?.attached);
}

pub fn expectInput(scenario: FullscreenReattachment, pane_id: core.PaneId) !void {
    try std.testing.expectEqual(pane_id, scenario.harness.client.model.planPaneInput(.focused).?.pane_id);
    try host_inputs.key(scenario.harness.client, try data.chord.parseKey("x"));
    try scenario.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try scenario.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(pane_id, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", message.pane_input.bytes);
}
