const TabLocationType = @import("telar-core").TabLocation;
const Source = @import("Source.zig");
const SourceCapture = @This();

contains: bool,
pane_count: u16,
contains_calls: usize = 0,
pane_calls: usize = 0,
last_location: ?TabLocationType = null,

pub fn source(capture: *SourceCapture) Source {
    return .{
        .context = capture,
        .contains_tab = containsTab,
        .running_panes = runningPanes,
    };
}

fn containsTab(context: *anyopaque, location: TabLocationType) bool {
    const capture: *SourceCapture = @ptrCast(@alignCast(context));
    capture.contains_calls += 1;
    capture.last_location = location;
    return capture.contains;
}

fn runningPanes(context: *anyopaque, location: TabLocationType) u16 {
    const capture: *SourceCapture = @ptrCast(@alignCast(context));
    capture.pane_calls += 1;
    capture.last_location = location;
    return capture.pane_count;
}
