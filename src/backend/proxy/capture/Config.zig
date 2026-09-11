const default_capture_part_bytes = @import("telar-core").default_capture_part_bytes;
const default_capture_exchange_bytes = @import("telar-core").default_capture_exchange_bytes;
const default_capture_total_bytes = @import("telar-core").default_capture_total_bytes;
const default_capture_join_timeout_ms = @import("telar-core").default_capture_join_timeout_ms;
const Config = @This();

enabled: bool = false,
max_part_bytes: usize = default_capture_part_bytes,
max_exchange_bytes: usize = default_capture_exchange_bytes,
max_total_bytes: usize = default_capture_total_bytes,
join_timeout_ms: u32 = default_capture_join_timeout_ms,

pub fn validate(config: Config) !void {
    if (config.max_part_bytes == 0 or config.max_exchange_bytes < 2 or config.max_total_bytes == 0) {
        return error.InvalidCaptureQuota;
    }

    if (config.max_part_bytes > config.max_exchange_bytes or config.max_exchange_bytes > config.max_total_bytes) {
        return error.InvalidCaptureQuota;
    }

    if (config.join_timeout_ms == 0) {
        return error.InvalidCaptureTimeout;
    }
}
