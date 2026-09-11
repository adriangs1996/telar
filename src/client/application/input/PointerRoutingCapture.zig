const pointer_routing = @import("pointer_routing.zig");
const ViewOutcome = @import("ViewOutcome.zig");
const PointerRoutingEffects = @import("PointerRoutingEffects.zig");
const PointerCommandType = @import("PointerCommand.zig");
const Capture = @This();

events: [4]pointer_routing.Event = undefined,
event_count: usize = 0,
copy_consumed: bool = false,
link_consumed: bool = false,
view_outcome: ViewOutcome = .{
    .consume_pane_input = false,
    .pointer_inside = true,
},
failure: pointer_routing.Failure = .none,

pub fn port(capture: *Capture) PointerRoutingEffects {
    return .{
        .context = capture,
        .copy_mode = copyMode,
        .view = view,
        .link = link,
        .pane = pane,
    };
}

fn record(capture: *Capture, event: pointer_routing.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn copyMode(raw_context: *anyopaque, command: PointerCommandType) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.copy_mode);

    if (capture.failure == .copy_mode) {
        return error.CopyModePointerFailed;
    }

    return capture.copy_consumed;
}

fn view(raw_context: *anyopaque, command: PointerCommandType) !ViewOutcome {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.view);

    if (capture.failure == .view) {
        return error.ViewPointerFailed;
    }

    return capture.view_outcome;
}

fn pane(raw_context: *anyopaque, command: PointerCommandType) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.pane);

    if (capture.failure == .pane) {
        return error.PanePointerFailed;
    }
}

fn link(raw_context: *anyopaque, command: PointerCommandType) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.record(.link);

    if (capture.failure == .link) {
        return error.LinkPointerFailed;
    }

    return capture.link_consumed;
}
