const Fragment = @import("Fragment.zig");
const Activity = @This();

bytes: usize = 0,
calls: usize = 0,
payload: [64]u8 = undefined,
payload_len: usize = 0,

pub fn observe(self: *Activity, fragment: Fragment) void {
    self.bytes += fragment.forwarded_bytes;
    self.calls += 1;

    @memcpy(self.payload[self.payload_len..][0..fragment.payload.len], fragment.payload);
    self.payload_len += fragment.payload.len;
}
