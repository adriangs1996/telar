const Suite = @This();

path: []const u8,
vt: bool = false,
libc: bool = false,
transport: bool = false,
schema: bool = false,
frontend: bool = false,
/// The shared client's integration tests, run by `test-client` too.
client_integration: bool = false,
isolated: bool = false,
