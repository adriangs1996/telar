pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
};
