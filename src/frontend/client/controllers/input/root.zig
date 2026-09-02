//! Client adapters for semantic input flows.

pub const action_routing = @import("action_routing.zig");
pub const attachment_prompts = @import("attachment_prompts.zig");
pub const actions = @import("actions.zig");
pub const copy_mode_pointer = @import("copy_mode_pointer.zig");
pub const copy_modes = @import("copy_modes.zig");
pub const host_inputs = @import("host_inputs.zig");
pub const key_routing = @import("key_routing.zig");
pub const name_prompts = @import("name_prompts.zig");
pub const pane_inputs = @import("pane_inputs.zig");
pub const pane_mouse_inputs = @import("pane_mouse_inputs.zig");
pub const pane_pastes = @import("pane_pastes.zig");
pub const paste_routing = @import("paste_routing.zig");
pub const pointer_routing = @import("pointer_routing.zig");
pub const view_interactions = @import("view_interactions.zig");

test {
    _ = action_routing;
    _ = attachment_prompts;
    _ = actions;
    _ = copy_mode_pointer;
    _ = copy_modes;
    _ = host_inputs;
    _ = key_routing;
    _ = name_prompts;
    _ = pane_inputs;
    _ = pane_mouse_inputs;
    _ = pane_pastes;
    _ = paste_routing;
    _ = pointer_routing;
    _ = view_interactions;
}
