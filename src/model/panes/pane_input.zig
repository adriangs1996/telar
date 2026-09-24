//! Planning pane input and the paste a pane is receiving.

const std = @import("std");
const tab_layout = @import("../workspace/tab_layout.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const copy_mode = @import("../input/copy_mode.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Reports whether a streamed pane paste owns host input.
///
/// ```zig
/// if (pane_input.pasteActive(model)) return;
/// ```
pub fn pasteActive(model: *const ClientModel) bool {
    return model.pane_paste != null;
}

/// Captures the attached focused pane and its current bracketed-paste mode.
///
/// ```zig
/// const session = pane_input.beginPaste(model) orelse return;
/// ```
pub fn beginPaste(model: *ClientModel) ?model_data.PanePasteSession {
    if (model.pane_paste != null) {
        return null;
    }

    const plan = planInput(model, .focused) orelse return null;
    const session: model_data.PanePasteSession = .{
        .pane_id = plan.pane_id,
        .bracketed_paste = plan.input_modes.bracketed_paste,
    };

    model.pane_paste = session;
    return session;
}

/// Finishes only the exact streamed paste that is still active.
///
/// ```zig
/// std.debug.assert(pane_input.finishPaste(model, session));
/// ```
pub fn finishPaste(model: *ClientModel, session: model_data.PanePasteSession) bool {
    const active = model.pane_paste orelse return false;
    if (!std.meta.eql(active, session)) {
        return false;
    }

    model.pane_paste = null;
    return true;
}

/// Releases a streamed paste only when its pane is being retired.
///
/// ```zig
/// _ = pane_input.releasePaste(model, pane_id);
/// ```
pub fn releasePaste(model: *ClientModel, pane_id: core.PaneId) bool {
    const session = model.pane_paste orelse return false;
    if (session.pane_id != pane_id) {
        return false;
    }

    model.pane_paste = null;
    return true;
}

/// Resolves one user-input target without exposing pane storage. Prompts
/// and copy mode own normal pane input exclusively. Physical key and paste
/// leases retain their exact pane across focus and authority changes.
///
/// ```zig
/// const plan = pane_input.planInput(model, .focused) orelse return;
/// ```
pub fn planInput(model: *const ClientModel, target: model_data.PaneInputTarget) ?model_data.PaneInputPlan {
    switch (target) {
        .focused, .pane => {
            if (model.name_prompt.active() or copy_mode.isActive(model)) {
                return null;
            }
        },
        .key_lease, .pointer_lease => {},
        .paste_session => |expected| {
            const active = model.pane_paste orelse return null;
            if (!std.meta.eql(active, expected)) {
                return null;
            }
        },
    }

    const pane = switch (target) {
        .focused => focused: {
            const slot = model.tabs.activeSlot() orelse return null;
            break :focused tab_layout.focusedPaneConst(model, slot) orelse return null;
        },
        .pane => |pane_id| explicit: {
            const slot = model.tabs.activeSlot() orelse return null;
            break :explicit model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id) orelse return null;
        },
        .key_lease, .pointer_lease => |pane_id| model.panes.findConst(pane_id) orelse return null,
        .paste_session => |session| model.panes.findConst(session.pane_id) orelse return null,
    };
    if (!pane.attached or pane.kind == .agent) {
        return null;
    }

    return .{
        .pane_id = pane.id,
        .input_modes = pane.input_modes,
    };
}
