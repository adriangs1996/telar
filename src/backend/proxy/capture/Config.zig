const core = @import("telar-core");
const Config = @This();

enabled: bool = false,
max_part_bytes: usize = core.default_capture_part_bytes,
max_exchange_bytes: usize = core.default_capture_exchange_bytes,
max_total_bytes: usize = core.default_capture_total_bytes,
join_timeout_ms: u32 = core.default_capture_join_timeout_ms,

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
