const core = @import("telar-core");
const data = @import("model");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const host_inputs = @import("../input/host_inputs.zig");
const FullscreenReattachment = @This();

harness: *TestHarness,

pub fn selectTab(self: FullscreenReattachment, index: u8, panes: []const core.PaneDescriptor) !void {
    const client = self.harness.client;
    _ = try client.executeAction(
        .{
            .select_tab = index,
        },
        .effect,
    );
    try self.harness.settle();
    var buffer: [512]u8 = undefined;
    const request = request: while (true) {
        switch (try self.harness.nextClientMessage(&buffer)) {
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
    try self.confirmAttachment(client.model.tabs.layout[client.model.tabs.active].focused().?);
}

pub fn confirmAttachment(self: FullscreenReattachment, pane_id: core.PaneId) !void {
    const client = self.harness.client;
    const terminal = self.harness.terminal;
    try std.testing.expect(client.model.request_lifecycle.tracker.hasPane(.attachment, pane_id));
    try self.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try self.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = pane_id }, message.open_pane.target);
    try std.testing.expectEqualDeep(
        data.tab_layout.contentSize(&client.model, client.model.tabs.active, pane_id, terminal.view.workbench()).?,
        message.open_pane.size,
    );
    const opened = try core.encodePaneOpened(&buffer, .{
        .request_id = message.open_pane.request_id,
        .pane_id = pane_id,
        .location = client.model.activeTabLocation().?,
        .created = false,
    });
    _ = try client.handleServerMessage(try core.decodeServer(opened));
    try std.testing.expect(client.model.panes.find(pane_id).?.attached);
}

pub fn expectInput(self: FullscreenReattachment, pane_id: core.PaneId) !void {
    try std.testing.expectEqual(pane_id, self.harness.client.model.planPaneInput(.focused).?.pane_id);
    try host_inputs.key(self.harness.terminal, try data.chord.parseKey("x"));
    try self.harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try self.harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(pane_id, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", message.pane_input.bytes);
}
