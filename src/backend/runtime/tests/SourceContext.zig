const SourceContext = @This();
const workspace_mod = @import("../../workspace/root.zig");
const source_namespace = @import("tab_snapshot_test.zig");
const tab_snapshot_query = @import("../application/queries/tab_snapshot.zig");
const std = @import("std");
workspaces: *workspace_mod.Repository,
live_location: source_namespace.schema.TabLocation,

pub fn source(context: *SourceContext) tab_snapshot_query.Source {
    return .{
        .context = context,
        .contains_tab = containsTab,
        .running_panes = runningPanes,
    };
}

fn containsTab(context: *anyopaque, location: source_namespace.schema.TabLocation) bool {
    const source_context: *SourceContext = @ptrCast(@alignCast(context));
    return source_context.workspaces.reader().contains(location);
}

fn runningPanes(context: *anyopaque, location: source_namespace.schema.TabLocation) u16 {
    const source_context: *SourceContext = @ptrCast(@alignCast(context));
    return if (std.meta.eql(source_context.live_location, location)) 1 else 0;
}
