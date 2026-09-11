const LayoutRecord = @This();

identity: u64,
last_used: u64,
/// Exactly the bytes of one `update_client_layout` request.
payload: []const u8,
