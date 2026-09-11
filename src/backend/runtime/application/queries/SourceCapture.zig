const SourceCapture = @This();
const source_namespace = @import("tab_snapshot.zig");
const Source = @import("Source.zig");
contains: bool,
pane_count: u16,
contains_calls: usize = 0,
pane_calls: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,

pub fn source(capture: *SourceCapture) Source {
    return .{
        .context = capture,
        .contains_tab = containsTab,
        .running_panes = runningPanes,
    };
}

fn containsTab(context: *anyopaque, location: source_namespace.schema.TabLocation) bool {
    const capture: *SourceCapture = @ptrCast(@alignCast(context));
    capture.contains_calls += 1;
    capture.last_location = location;
    return capture.contains;
}

fn runningPanes(context: *anyopaque, location: source_namespace.schema.TabLocation) u16 {
    const capture: *SourceCapture = @ptrCast(@alignCast(context));
    capture.pane_calls += 1;
    capture.last_location = location;
    return capture.pane_count;
}
