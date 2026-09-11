const PanesCapture = @This();
const pane_mod = @import("../../../pane/root.zig");
const LaunchPane = @import("OpenPaneLaunchPane.zig");
const PrepareView = @import("PrepareView.zig");
const Panes = @import("Panes.zig");
const source_namespace = @import("open_pane.zig");
pane_result: ?pane_mod.PaneLaunched = null,
first_result: ?pane_mod.PaneLaunched = null,
launch_result: ?pane_mod.PaneLaunched = null,
launch_failure: ?anyerror = null,
view_failure: ?anyerror = null,
attach_failure: ?anyerror = null,
find_count: usize = 0,
first_count: usize = 0,
launch_count: usize = 0,
view_count: usize = 0,
attach_count: usize = 0,
last_launch: ?LaunchPane = null,
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

fn find(context: *anyopaque, _: source_namespace.schema.PaneId) ?pane_mod.PaneLaunched {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.find_count += 1;
    return capture.pane_result;
}

fn first(context: *anyopaque, _: source_namespace.schema.TabLocation) ?pane_mod.PaneLaunched {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.first_count += 1;
    return capture.first_result;
}

fn launch(context: *anyopaque, request: LaunchPane) !pane_mod.PaneLaunched {
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

fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
    const capture: *PanesCapture = @ptrCast(@alignCast(context));
    capture.attach_count += 1;

    if (capture.attach_failure) |failure| {
        return failure;
    }
}
