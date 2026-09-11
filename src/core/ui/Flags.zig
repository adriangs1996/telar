const Underline = @import("Style.zig").Underline;

/// Attributes preserve the emulator's bit layout for the VT-to-cell bitcast.
/// The layout is checked beside that conversion in backend/pane/blit.zig.
pub const Flags = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: Underline = .none,
    _padding: u5 = 0,
};
