const RepositoryType = @import("../../workspace/Repository.zig");
const TabLocationType = @import("telar-core").TabLocation;
const SourceType = @import("../application/queries/Source.zig");
const std = @import("std");
const SourceContext = @This();

workspaces: *RepositoryType,
live_location: TabLocationType,

pub fn source(context: *SourceContext) SourceType {
    return .{
        .context = context,
        .contains_tab = containsTab,
        .running_panes = runningPanes,
    };
}

fn containsTab(context: *anyopaque, location: TabLocationType) bool {
    const source_context: *SourceContext = @ptrCast(@alignCast(context));
    return source_context.workspaces.reader().contains(location);
}

fn runningPanes(context: *anyopaque, location: TabLocationType) u16 {
    const source_context: *SourceContext = @ptrCast(@alignCast(context));
    return if (std.meta.eql(source_context.live_location, location)) 1 else 0;
}
