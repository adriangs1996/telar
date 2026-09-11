//! Vertical contract tests for the runtime tab-snapshot flow.

const std = @import("std");
const core = @import("telar-core");
const tab_snapshot_query = @import("../application/queries/tab_snapshot.zig");
const tab_snapshot_controller = @import("../entrypoints/requests/tab_snapshot.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;

const SourceContext = @import("SourceContext.zig");

test "a live aggregate tab crosses query and controller boundaries" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var source_context: SourceContext = .{
        .workspaces = &workspaces,
        .live_location = location,
    };
    var handler: tab_snapshot_query.Handler = .{ .source = source_context.source() };
    var responses: delivery_mod.ResponseQueue = .{};
    var controller = tab_snapshot_controller.Controller.init(&responses, handler.executor());
    const request_id: schema.RequestId = @enumFromInt(41);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = location,
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_snapshot);
    try std.testing.expectEqual(request_id, response.tab_snapshot.request_id);
    try std.testing.expectEqualDeep(location, response.tab_snapshot.location);
}
