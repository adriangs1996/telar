pub const Shape = enum(u3) { default = 0, block = 1, bar = 2, underline = 3, hollow = 4 };

pub const CursorAppearance = packed struct(u8) {
    shape: Shape = .default,
    blink: bool = true,
    _reserved: u4 = 0,
};
