const std = @import("std");
const core = @import("telar-core");
const PaneFixture = @import("PaneFixture.zig");
const Application = @import("../application/Application.zig");
const Handler = @import("../application/commands/EditorOpenHandler.zig");
const ClientKey = @import("../../history/ClientKey.zig");
const event = @import("../event.zig");

test "editor requests exclude other tabs bound concurrent work and reject stale panes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const editor = try fixture.createPane(@enumFromInt(8));
    defer editor.destroy();
    defer editor.session.shutdown();
    editor.agent_process_cache.setName("nvim");
    const other = try fixture.createPane(@enumFromInt(9));
    defer other.destroy();
    defer other.session.shutdown();
    other.agent_process_cache.setName("nvim");
    other.location.tab_id = @enumFromInt(100);
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(gpa, .{}) };
    defer inherited.block.deinit(gpa);
    var events: [1]event.Event = undefined;
    var select: std.Io.Select(event.Event) = .init(io, &events);
    const application = try gpa.create(Application);
    defer {
        select.cancelDiscard();
        gpa.destroy(application);
    }
    application.* = undefined;
    application.io = io;
    application.select = &select;
    application.inherited_environment = inherited;
    application.editor_open = .{};
    application.model = .{ .panes = .{} };
    try application.model.panes.insert(fixture.pane);
    try application.model.panes.insert(editor);
    try application.model.panes.insert(other);
    const handler: Handler = .{ .application = application };
    const request: core.OpenEditor = .{
        .request_id = @enumFromInt(1),
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
        .editor = "nvim",
        .path = "/tmp/file",
    };
    const client: ClientKey = .{ .id = 1, .generation = 1 };
    try handler.execute(.{ .client = client, .message = request });
    try std.testing.expectError(error.EditorOpenBusy, handler.execute(.{ .client = client, .message = request }));
    const completed = (try select.await()).editor_opened;
    try std.testing.expectEqual(@as(usize, 1), completed.candidate_count);
    try std.testing.expectEqual(editor.id, completed.candidates[0].pane.id);
    try std.testing.expectEqual(core.EditorOpened.Outcome.unavailable, handler.complete(completed).outcome);
    try std.testing.expect(!application.editor_open.busy);

    try handler.execute(.{ .client = client, .message = request });
    const stale = (try select.await()).editor_opened;
    fixture.pane.close_requested = true;
    try std.testing.expectEqual(core.EditorOpened.Outcome.failed, handler.complete(stale).outcome);
    try std.testing.expectError(error.PaneExited, handler.execute(.{ .client = client, .message = request }));
    fixture.pane.close_requested = false;
    var replaced = request;
    replaced.pane_generation += 1;
    try std.testing.expectError(error.PaneNotFound, handler.execute(.{ .client = client, .message = replaced }));
}
