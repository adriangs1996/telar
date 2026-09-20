pub const CapturedSpan = extern struct {
    start: u32,
    end: u32,
    capture: [*:0]const u8,
};
