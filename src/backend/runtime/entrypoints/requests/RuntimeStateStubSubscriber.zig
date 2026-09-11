const ClientIdentityType = @import("telar-core").ClientIdentity;
const StubSubscriber = @This();

call_count: usize = 0,

pub fn requestRuntimeState(stub: *StubSubscriber, _: ClientIdentityType) !void {
    stub.call_count += 1;
}
