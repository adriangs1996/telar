const CapturedSpan = @import("CapturedSpan.zig").CapturedSpan;

pub const NativeRequest = extern struct {
    language: [*:0]const u8,
    source: [*]const u8,
    source_len: usize,
    spans: [*]CapturedSpan,
    capacity: usize,
    count: usize = 0,
};
