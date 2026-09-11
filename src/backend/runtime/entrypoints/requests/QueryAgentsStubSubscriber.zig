const StubSubscriber = @This();

call_count: usize = 0,

pub fn requestAgentSnapshot(stub: *StubSubscriber) void {
    stub.call_count += 1;
}
