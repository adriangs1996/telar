//! Native tab gestures use only the dispatcher's delivered control geometry.
const GuiClient = @import("../../GuiClient.zig");
const Event = @import("../../input/event.zig").Event;
const Target = @import("Target.zig");

/// Runs after physical ownership has been recorded by the dispatcher.
/// Example: `if (try tab_drag.apply(gui, event, result.target)) return true;`
pub fn apply(gui: *GuiClient, event: Event, owner: ?Target) !bool {
    const state = &gui.widgets;
    const drag = &state.tab_drag;
    drag.validate(&gui.app.model);
    if (event == .focus and !event.focus) {
        drag.cancel();
    }
    if (event == .key and event.key.code == .escape and drag.captured) {
        drag.cancel();
        state.dispatcher.discardPointer(.left);
        state.dispatcher.revision +%= 1;
        if (event.key.physical) |physical| {
            _ = state.dispatcher.keys.acquire(physical, .discarded);
        }

        return true;
    }
    if (event != .pointer or event.pointer.button != .left) {
        return false;
    }

    const pointer = event.pointer;
    const point: [2]f64 = .{ pointer.x / state.tab_drag_step, pointer.y / state.tab_drag_step };
    if (pointer.kind == .press) {
        const target = owner orelse return false;
        if (target.layer != 0 or !target.enabled or target.action != .intent or target.action.intent != .select_tab or gui.app.model.name_prompt.active()) {
            return false;
        }

        const tab_id = target.action.intent.select_tab;
        const workspace = gui.app.model.workspace.workspace orelse return false;
        if (gui.app.model.workspace.indexOf(tab_id) != null) {
            drag.begin(.{ .workspace = workspace, .tab_id = tab_id }, point);
            state.tab_drop_slots.capture(state.dispatcher.maps.presented());
            state.tab_pointer = .{ pointer.x, pointer.y };
            state.tab_grab_offset = pointer.x - target.bounds.x;
        }

        return false;
    }
    if (!drag.captured) {
        return false;
    }
    if (pointer.kind == .leave) {
        drag.destination = null;
        state.dispatcher.revision +%= 1;
        return false;
    }
    if (!pointer.retained()) {
        return false;
    }

    if (owner == null or owner.?.layer != 0 or owner.?.action != .intent or owner.?.action.intent != .select_tab) {
        drag.cancel();
    }

    state.tab_pointer = .{ pointer.x, pointer.y };
    drag.update(point, state.tab_drop_slots.at(pointer));
    state.dispatcher.revision +%= 1;
    if (pointer.kind == .release) {
        if (drag.finish()) |move| {
            var handler = @import("telar-client").controllers.tab_moves.requestHandler(&gui.app);
            if (try handler.execute(.{ .location = move.location, .direction = move.direction, .relative_to = move.relative_to })) {
                state.tab_drop_pending = move;
            }
        }
    }

    return true;
}
