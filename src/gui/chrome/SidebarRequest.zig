//! What the sidebar band is asked to be before the window clamps it: the
//! shared model's visibility and the GUI's width preference in logical pixels.
visible: bool = false,
logical_width: f32 = @import("telar-client").GuiSidebar.default_width,
