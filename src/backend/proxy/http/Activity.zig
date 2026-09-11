const Activity = @This();
const Fragment = @import("Fragment.zig");
bytes: usize = 0,
calls: usize = 0,
payload: [64]u8 = undefined,
payload_len: usize = 0,

pub fn observe(activity: *Activity, fragment: Fragment) void {
    activity.bytes += fragment.forwarded_bytes;
    activity.calls += 1;

    @memcpy(activity.payload[activity.payload_len..][0..fragment.payload.len], fragment.payload);
    activity.payload_len += fragment.payload.len;
}
