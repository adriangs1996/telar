const data = @import("model");
const goto_picker = @import("goto_picker.zig");
const Input = @This();

/// Cells the picker covers; `path_picker.modalArea` placed them.
placement: data.PathPickerPlacement,
field: *goto_picker.Field,
selection: u16,
state: *const data.PathPickerState,
/// True when a pixel-aligned frame already surrounds the modal, so the
/// cell border must not be drawn on top of it.
graphical_frame: bool = false,
