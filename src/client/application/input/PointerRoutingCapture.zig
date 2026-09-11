const Capture = @This();
const source_namespace = @import("pointer_routing.zig");
const ViewOutcome = @import("ViewOutcome.zig");
const Effects = @import("PointerRoutingEffects.zig");
events: [4]source_namespace.Event = undefined,
event_count: usize = 0,
copy_consumed: bool = false,
link_consumed: bool = false,
view_outcome: ViewOutcome = .{
    .consume_pane_input = false,
    .pointer_inside = true,
},
failure: source_namespace.Failure = .none,

pub fn port(capture: *Capture) Effects {
    return .{
        .context = capture,
        .copy_mode = copyMode,
        .view = view,
        .link = link,
        .pane = pane,
    };
}

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn copyMode(raw_context: *anyopaque, command: source_namespace.PointerCommand) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.copy_mode);

    if (capture.failure == .copy_mode) {
        return error.CopyModePointerFailed;
    }

    return capture.copy_consumed;
}

fn view(raw_context: *anyopaque, command: source_namespace.PointerCommand) !ViewOutcome {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.view);

    if (capture.failure == .view) {
        return error.ViewPointerFailed;
    }

    return capture.view_outcome;
}

fn pane(raw_context: *anyopaque, command: source_namespace.PointerCommand) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.pane);

    if (capture.failure == .pane) {
        return error.PanePointerFailed;
    }
}

fn link(raw_context: *anyopaque, command: source_namespace.PointerCommand) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.link);

    if (capture.failure == .link) {
        return error.LinkPointerFailed;
    }

    return capture.link_consumed;
}
