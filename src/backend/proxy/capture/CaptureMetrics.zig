const Metrics = @This();

started: u64 = 0,
truncated: u64 = 0,
truncated_part: u64 = 0,
truncated_exchange: u64 = 0,
truncated_total: u64 = 0,
skipped: u64 = 0,
dropped_queue: u64 = 0,
decode_failed: u64 = 0,
queued: u64 = 0,
queue_high_water: u64 = 0,
