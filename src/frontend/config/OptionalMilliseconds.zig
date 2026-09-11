const OptionalMilliseconds = @This();

index: c_int,
name: [*:0]const u8,
default_ns: u64,
minimum_ms: u64,
maximum_ms: u64,
