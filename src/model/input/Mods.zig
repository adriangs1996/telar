pub const Mods = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};
