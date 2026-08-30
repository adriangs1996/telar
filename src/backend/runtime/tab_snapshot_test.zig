//! Vertical contract tests for the runtime tab-snapshot flow.

const std = @import("std");
const core = @import("telar-core");
const tab_snapshot_query = @import("queries/tab_snapshot.zig");
const tab_snapshot_controller = @import("controllers/tab_snapshot.zig");
const response_queue = @import("response_queue.zig");
const workspace_mod = @import("../workspace/root.zig");

const schema = core.schema;

const SourceContext = struct {
    workspaces: *workspace_mod.Repository,
    live_location: schema.TabLocation,

    fn source(context: *SourceContext) tab_snapshot_query.Source {
        return .{
            .context = context,
            .contains_tab = containsTab,
            .running_panes = runningPanes,
        };
    }

    fn containsTab(context: *anyopaque, location: schema.TabLocation) bool {
        const source_context: *SourceContext = @ptrCast(@alignCast(context));
        return source_context.workspaces.reader().contains(location);
    }

    fn runningPanes(context: *anyopaque, location: schema.TabLocation) u16 {
        const source_context: *SourceContext = @ptrCast(@alignCast(context));
        return if (std.meta.eql(source_context.live_location, location)) 1 else 0;
    }
};

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
    var responses: response_queue.ResponseQueue = .{};
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
