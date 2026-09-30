//! The native sidebar band preference: its width in logical pixels. The GUI
//! scales it once per display and clamps it to the window; the TUI keeps its
//! own column preference in the shared model.
pub const min_width: f32 = 220;
/// Wide enough for a T3-style sidebar on a large display; the window still
/// clamps it so the workbench keeps its columns.
pub const max_width: f32 = 800;
pub const default_width: f32 = 284;

width: f32 = default_width,
