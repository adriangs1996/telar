const LogName = @import("DiagnosticLogName.zig");

export fn classify_name(bytes: [*]const u8, length: usize) u64 {
    const parsed = LogName.parse(bytes[0..length]) orelse return 0;
    return @as(u64, parsed.pid) |
        (@as(u64, @intFromEnum(parsed.role)) << 32) |
        (@as(u64, @intFromBool(parsed.rotated)) << 33) |
        (@as(u64, 1) << 34) |
        (@as(u64, parsed.endpoint_len) << 35);
}
