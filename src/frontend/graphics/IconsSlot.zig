const IconType = @import("telar-client").Icon;
const Slot = @This();

icon: IconType,
foreground: [3]u8,
background: [3]u8,
/// Cells the slot spans sideways. Glyphs take one; artwork may take two
/// so its square can grow to the row's height.
columns: u8,
