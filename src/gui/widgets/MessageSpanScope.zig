//! A bounded inline style or link scope within one borrowed source string.
const Span = @import("MessageSpan.zig");

start: usize,
end: usize,
after: usize,
kind: @FieldType(Span, "kind") = .plain,
destination: ?[]const u8 = null,
link_offset: u32 = 0,
