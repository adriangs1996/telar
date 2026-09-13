pub const InputEvent = extern struct {
    kind: u32,
    code: u32 = 0,
    mods: u32 = 0,
    phase: u32 = 1,
    text: ?[*]const u8 = null,
    len: usize = 0,
    physical: u32 = 0,
    button: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
};
