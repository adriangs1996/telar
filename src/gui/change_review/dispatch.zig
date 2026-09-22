//! Routes only delivered review targets; late native events cannot replace owners.
const event_module = @import("../input/event.zig");
const std = @import("std");
const Widget = @import("Widget.zig");
const Id = @import("../widgets/interaction/Id.zig");

/// Clipboard completions arrive after the native input queue resolves the host request.
/// Example: `_ = try dispatch.apply(widget, event);`
pub fn apply(widget: *Widget, event: event_module.Event) !bool {
    const state = widget.widgets orelse return true;
    var route = if (event == .key and widget.ownsKey(event.key)) state.dispatcher.editorKey(event.key) else state.dispatcher.route(event);
    if (event == .accessibility) {
        const action = event.accessibility;
        route.target = state.dispatcher.maps.presented().find(.{ .target_id = action.target_id, .generation = action.generation }) orelse return true;
        route.consumed = true;
        if (action.action == .focus) {
            route.focus_changed = state.dispatcher.focus(route.target.?.id);
        }
    } else if (explicitTarget(event)) |id| {
        const write = event == .clipboard and event.clipboard.operation == .write;
        if (write) {
            route.target = state.dispatcher.maps.presented().find(id) orelse return true;
        } else if (route.target == null or !route.target.?.id.eql(id) or !std.meta.eql(state.dispatcher.focused, @as(?Id, id))) {
            return true;
        }
    }
    if (route.focus_changed or (event == .focus and !event.focus)) {
        state.cancelComposition();
    }
    _ = try widget.input(event, route);
    return true;
}

fn explicitTarget(event: event_module.Event) ?Id {
    return switch (event) {
        .text => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .key => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .composition => |value| .{ .target_id = value.target_id, .generation = value.generation },
        .clipboard => |value| if (value.target_id == 0) null else .{ .target_id = value.target_id, .generation = value.generation },
        .delete_surrounding => |value| .{ .target_id = value.target_id, .generation = value.generation },
        else => null,
    };
}
