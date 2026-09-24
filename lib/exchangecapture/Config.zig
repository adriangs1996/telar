//! Capture bounds: per part, per exchange and in total, and how long a half
//! waits for its peer. Capture stays off until it is enabled.
const Config = @This();

enabled: bool = false,
max_part_bytes: usize = 4 * 1024 * 1024,
max_exchange_bytes: usize = 8 * 1024 * 1024,
max_total_bytes: usize = 64 * 1024 * 1024,
join_timeout_ms: u32 = 30_000,

pub fn validate(self: Config) !void {
    if (self.max_part_bytes == 0 or self.max_exchange_bytes < 2 or self.max_total_bytes == 0) {
        return error.InvalidCaptureQuota;
    }

    if (self.max_part_bytes > self.max_exchange_bytes or self.max_exchange_bytes > self.max_total_bytes) {
        return error.InvalidCaptureQuota;
    }

    if (self.join_timeout_ms == 0) {
        return error.InvalidCaptureTimeout;
    }
}
