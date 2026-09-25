//! Attachment rows and the client's workspace view, through the flow's
//! procedures over a real runtime model.

const std = @import("std");
const core = @import("telar-core");
const RequestFixture = @import("RequestFixture.zig");
const pane_attachment = @import("../pane_attachment.zig");
const Attachments = @import("../attachment/Attachments.zig");

test "releasing the last pane reports departure and keeps the view until the client leaves" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const first = try fixture.openPane();
    var launch_buffer: [64]u8 = undefined;
    try fixture.send(.{ .create_pane = .{
        .request_id = @enumFromInt(41),
        .location = first.location,
        .size = .{ .cols = 30, .rows = 8 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } });
    fixture.clearResponses();

    const model = &fixture.runtime.model;
    const session = fixture.session;
    const workspace = first.location.workspace;
    const second_id = model.attachments.at(session.slot, 1).?.pane.id;

    try std.testing.expect(!pane_attachment.leaveWorkspace(model, session, workspace));
    try std.testing.expect(pane_attachment.release(model, session, try core.pane(99)) == null);

    const first_released = pane_attachment.release(model, session, first.id).?;

    try std.testing.expectEqual(first.id, first_released.pane_id);
    try std.testing.expectEqualDeep(workspace, first_released.workspace);
    try std.testing.expect(!first_released.last_attachment);
    try std.testing.expectEqual(@as(usize, 1), model.attachments.len(session.slot));
    try std.testing.expect(session.observes(workspace));
    try std.testing.expect(model.attachments.find(session.slot, first.id) == null);
    try std.testing.expect(first.observers & Attachments.observer(session.slot) == 0);

    const second_released = pane_attachment.release(model, session, second_id).?;

    try std.testing.expect(second_released.last_attachment);
    try std.testing.expectEqual(@as(usize, 0), model.attachments.len(session.slot));
    try std.testing.expect(session.observes(workspace));
    try std.testing.expect(!pane_attachment.leaveWorkspace(model, session, .{ .workspace = try core.workspace(99) }));
    try std.testing.expect(pane_attachment.leaveWorkspace(model, session, workspace));
    try std.testing.expect(session.workspace == null);
}

test "a client attaches only panes of the workspace it views" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const pane = try fixture.openPane();
    const model = &fixture.runtime.model;
    const other = try fixture.addClient();
    other.workspace = .{ .workspace = try core.workspace(99) };

    try std.testing.expectError(error.WorkspaceMismatch, pane_attachment.attach(model, other, pane));
    try std.testing.expect(pane.observers & Attachments.observer(other.slot) == 0);

    other.workspace = null;
    other.shared_graphics = true;
    const attachment = try pane_attachment.attach(model, other, pane);

    try std.testing.expect(attachment.graphics.shared_transport);
    try std.testing.expectEqualDeep(pane.location.workspace, other.workspace.?);
    try std.testing.expectEqual(attachment, try pane_attachment.attach(model, other, pane));
}
