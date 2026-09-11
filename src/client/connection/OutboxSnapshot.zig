const Snapshot = @This();

depth: u8 = 0,
high_water: u8 = 0,
saturated: u64 = 0,
coalesced_input: u64 = 0,
coalesced_resize: u64 = 0,
coalesced_ack: u64 = 0,
coalesced_client_layout: u64 = 0,
