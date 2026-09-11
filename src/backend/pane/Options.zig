const Options = @This();
const source_namespace = @import("blit.zig");
/// Cells to draw as selected, in coordinates relative to `area`.
///
/// Passed in rather than read off the render state because the gesture
/// belongs to the application: the emulator has a selection concept, but
/// which drag the user is making, and whether it is even aimed at this
/// pane, is not something it can know.
selection: ?source_namespace.sel.Range = null,

/// Draw the pane's cursor. Off for unfocused panes: two visible cursors in
/// one screen is worse than none, and the real cursor is placed by `term`.
cursor: bool = false,

/// Copy every row regardless of its dirty flag.
///
/// Needed whenever the destination changed without the source changing -
/// the pane moved, the window resized, a modal that covered it closed -
/// because the emulator has no idea any of that happened.
force: bool = false,

/// Destination rows copied by this blit.
///
/// A runtime can retain this slice until it builds a frame, then compare
/// only the rows which may have changed. The slice belongs to the caller
/// and must cover the destination buffer's height. Marks accumulate so
/// several blits can be folded without losing earlier damage.
damaged_rows: ?[]bool = null,
