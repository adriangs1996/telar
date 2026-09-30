//! Capture bounds: per part, per exchange and in total, and how long a half
//! waits for its peer. Capture stays off until it is enabled.
//!
//! The defaults fit an agent's long-context request with images in one
//! part, and a streamed model response that runs for minutes in one
//! exchange. Each bound has a ceiling so a typo cannot let capture grow
//! without bound.
const std = @import("std");
const Config = @This();

const mib = 1024 * 1024;

/// The largest `max_part_bytes` and `max_exchange_bytes` accepted: a whole
/// exchange stays well inside one tap frame.
pub const max_exchange_ceiling: usize = 64 * mib;
/// The largest `max_total_bytes` accepted.
pub const max_total_ceiling: usize = 1024 * mib;
/// The longest `join_timeout_ms` accepted: one hour.
pub const max_join_timeout_ms: u32 = 60 * std.time.ms_per_min;

enabled: bool = false,
max_part_bytes: usize = 16 * mib,
max_exchange_bytes: usize = 32 * mib,
max_total_bytes: usize = 128 * mib,
/// How long the first half of an exchange waits for the other. A request
/// half waits while its response streams, so this covers the longest
/// streamed response expected: fifteen minutes.
join_timeout_ms: u32 = 15 * std.time.ms_per_min,

pub fn validate(self: Config) !void {
    if (self.max_part_bytes == 0 or self.max_exchange_bytes < 2 or self.max_total_bytes == 0) {
        return error.InvalidCaptureQuota;
    }

    if (self.max_part_bytes > self.max_exchange_bytes or self.max_exchange_bytes > self.max_total_bytes) {
        return error.InvalidCaptureQuota;
    }

    if (self.max_exchange_bytes > max_exchange_ceiling or self.max_total_bytes > max_total_ceiling) {
        return error.InvalidCaptureQuota;
    }

    if (self.join_timeout_ms == 0 or self.join_timeout_ms > max_join_timeout_ms) {
        return error.InvalidCaptureTimeout;
    }
}
