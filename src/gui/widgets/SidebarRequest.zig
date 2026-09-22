//! What the sidebar band is asked to be before the window clamps it: the
//! shared model's visibility and the GUI's width preference in logical pixels.
const client = @import("telar-client");
visible: bool = false,
logical_width: f32 = client.GuiSidebar.default_width,
