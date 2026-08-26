//! Values shared by every host platform adapter.

pub const Size = struct {
    cols: u16,
    rows: u16,
    width_px: u16 = 0,
    height_px: u16 = 0,
};
