pub const HostRequest = extern struct {
    kind: u32 = 0,
    request_id: u64 = 0,
    target_id: u64 = 0,
    generation: u64 = 0,
    text: ?[*]const u8 = null,
    len: usize = 0,
};
