const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const OpenPaneLaunchPane = @import("OpenPaneLaunchPane.zig");
const PrepareView = @import("PrepareView.zig");
const Panes = @import("Panes.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const PanesCapture = @This();

pane_result: ?PaneLaunchedType = null,
first_result: ?PaneLaunchedType = null,
launch_result: ?PaneLaunchedType = null,
launch_failure: ?anyerror = null,
view_failure: ?anyerror = null,
attach_failure: ?anyerror = null,
find_count: usize = 0,
first_count: usize = 0,
launch_count: usize = 0,
view_count: usize = 0,
attach_count: usize = 0,
last_launch: ?OpenPaneLaunchPane = null,
last_view: ?PrepareView = null,

pub fn port(capture: *PanesCapture) Panes {
    return .{
        .context = capture,
        .find = find,
        .first = first,
        .launch = launch,
        .prepare_view = prepareView,
        .attach = attach,
    };
}

fn find(context: *anyopaque, _: PaneIdType) ?PaneLaunchedType {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.find_count += 1;
    return capture.pane_result;
}

fn first(context: *anyopaque, _: TabLocationType) ?PaneLaunchedType {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.first_count += 1;
    return capture.first_result;
}

fn launch(context: *anyopaque, request: OpenPaneLaunchPane) !PaneLaunchedType {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.launch_count += 1;
    capture.last_launch = request;

    if (capture.launch_failure) |failure| {
        return failure;
    }

    return capture.launch_result.?;
}

fn prepareView(context: *anyopaque, request: PrepareView) !void {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.view_count += 1;
    capture.last_view = request;

    if (capture.view_failure) |failure| {
        return failure;
    }
}

fn attach(context: *anyopaque, _: PaneLaunchedType) !void {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.attach_count += 1;

    if (capture.attach_failure) |failure| {
        return failure;
    }
}
