//! Semantic input flows owned by the client application.

pub const action_routing = @import("action_routing.zig");
pub const clipboard_image = @import("clipboard_image.zig");
pub const clipboard_image_delivery = @import("clipboard_image_delivery.zig");
pub const copy_mode = @import("copy_mode.zig");
pub const copy_mode_pointer = @import("copy_mode_pointer.zig");
pub const key_routing = @import("key_routing.zig");
pub const lua_action = @import("lua_action.zig");
pub const name_prompt = @import("name_prompt.zig");
pub const name_prompt_opening = @import("name_prompt_opening.zig");
pub const native_action = @import("native_action.zig");
pub const pane_input = @import("pane_input.zig");
pub const pane_mouse = @import("pane_mouse.zig");
pub const pane_paste = @import("pane_paste.zig");
pub const paste_routing = @import("paste_routing.zig");
pub const plugin_action = @import("plugin_action.zig");
pub const plugin_action_delivery = @import("plugin_action_delivery.zig");
pub const pointer_routing = @import("pointer_routing.zig");
pub const view_interaction = @import("view_interaction.zig");

test {
    _ = action_routing;
    _ = clipboard_image;
    _ = clipboard_image_delivery;
    _ = copy_mode;
    _ = copy_mode_pointer;
    _ = key_routing;
    _ = lua_action;
    _ = name_prompt;
    _ = name_prompt_opening;
    _ = native_action;
    _ = pane_input;
    _ = pane_mouse;
    _ = pane_paste;
    _ = paste_routing;
    _ = plugin_action;
    _ = plugin_action_delivery;
    _ = pointer_routing;
    _ = view_interaction;
}
