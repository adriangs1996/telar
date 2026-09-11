const FakeScheduler = @This();
const FakeCapability = @import("FakeCapability.zig");
scheduled: usize = 0,
failure: ?anyerror = null,

pub fn schedule(scheduler: *FakeScheduler, _: *FakeCapability) !void {
    scheduler.scheduled += 1;

    if (scheduler.failure) |err| {
        return err;
    }
}
