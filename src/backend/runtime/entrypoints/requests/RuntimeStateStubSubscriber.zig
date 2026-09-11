const StubSubscriber = @This();
const schema = @import("telar-core").schema;
call_count: usize = 0,

pub fn requestRuntimeState(stub: *StubSubscriber, _: schema.ClientIdentity) !void {
    stub.call_count += 1;
}
