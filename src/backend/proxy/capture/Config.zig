const core = @import("telar-core");
const Config = @This();

enabled: bool = false,
max_part_bytes: usize = core.default_capture_part_bytes,
max_exchange_bytes: usize = core.default_capture_exchange_bytes,
max_total_bytes: usize = core.default_capture_total_bytes,
join_timeout_ms: u32 = core.default_capture_join_timeout_ms,

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
