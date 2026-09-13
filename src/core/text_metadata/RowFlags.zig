//! Physical row semantics emitted by the VT, independent of painted blanks.
pub const RowFlags = packed struct(u8) {
    wrap: bool = false,
    continuation: bool = false,
    wide_padding: bool = false,
    hyperlinks: bool = false,
    reserved: u4 = 0,
};
