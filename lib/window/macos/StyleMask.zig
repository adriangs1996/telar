/// The `NSWindowStyleMask` bits telar's window reads and toggles.
pub const StyleMask = enum(usize) {
    fullscreen = 1 << 14,
    full_content = 1 << 15,
};
