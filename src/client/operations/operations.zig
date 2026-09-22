//! Shared client operations grouped by behavior. Process event switches call
//! these functions with concrete client state; host services keep their ports.

pub const ClipboardImageCompletion = @import("host/Completion.zig");
pub const bar_updates = @import("configuration/bar_updates.zig");
pub const copy_mode_pointer = @import("input/copy_mode_pointer.zig");
pub const favicons = @import("workspaces/favicons.zig");
pub const name_prompts = @import("input/name_prompts.zig");
pub const pane_graphics = @import("panes/pane_graphics.zig");
pub const pane_mouse_inputs = @import("input/pane_mouse_inputs.zig");
pub const paste_routing = @import("input/paste_routing.zig");
pub const path_completions = @import("input/path_completions.zig");
pub const pointer_routing = @import("input/pointer_routing.zig");
pub const view_interactions = @import("input/view_interactions.zig");
