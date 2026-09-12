pub const InputEvent = extern struct {
    kind: u32,
    code: u32 = 0,
    mods: u32 = 0,
    phase: u32 = 1,
    text: ?[*]const u8 = null,
    len: usize = 0,
};
